// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart';

import 'clients.dart';
import 'environment.dart';
import 'metric.dart';
import 'results.dart';
import 'rss_sampler.dart';
import 'scenario.dart';
import 'server.dart';
import 'stats.dart';

/// Receives progress notifications from a [BenchmarkRunner].
abstract interface class RunnerListener {
  /// Called after checking whether [variant] can be benchmarked.
  void onVariantChecked(VariantInfo variant);

  /// Called after every variant has been checked.
  void onVariantsChecked(List<VariantInfo> variants);

  /// Called before [scenario] is run with each client variant.
  void onScenarioStarted(Scenario scenario);

  /// Called before [scenario] is run with [variant].
  void onRunStarted(Scenario scenario, ClientVariant variant);

  /// Called after [scenario] has been run with every client variant.
  void onScenarioFinished(Scenario scenario, List<RunResult> results);
}

/// Runs scenarios against client variants.
class BenchmarkRunner {
  BenchmarkRunner({
    required this.server,
    required this.environment,
    required this.variants,
    required this.scenarios,
    required this.configuration,
    this.trialTimeout = const Duration(minutes: 2),
    this.listener,
    this.verbose = false,
  });

  final BenchmarkServer server;
  final Environment environment;
  final List<ClientVariant> variants;
  final List<Scenario> scenarios;
  final RunConfiguration configuration;

  /// The maximum duration of a single trial.
  final Duration trialTimeout;

  final RunnerListener? listener;

  /// Whether to log unexpected, asynchronous errors.
  final bool verbose;

  /// How long to wait for a request made while checking or priming a client.
  static const _primeTimeout = Duration(seconds: 10);

  /// How long to wait for abandoned work to stop after a run fails.
  static const _settleTimeout = Duration(seconds: 10);

  /// Runs every scenario with every available client variant.
  Future<BenchmarkReport> run() async {
    final startedAt = DateTime.now();
    final sampler = await RssSampler.start();
    try {
      final variantInfos = <VariantInfo>[];
      final available = <ClientVariant>[];
      for (final variant in variants) {
        final reason = await _check(variant);
        final info = VariantInfo(
          id: variant.id,
          client: variant.client,
          protocol: variant.protocol,
          unavailableReason: reason,
        );
        listener?.onVariantChecked(info);
        variantInfos.add(info);
        if (reason == null) available.add(variant);
      }
      listener?.onVariantsChecked(variantInfos);

      final results = <RunResult>[];
      for (final (index, scenario) in scenarios.indexed) {
        listener?.onScenarioStarted(scenario);
        final scenarioResults = <RunResult>[];
        // Rotate the order of the variants from one scenario to the next, so
        // that no variant always runs first (e.g. while the process's heap is
        // still growing) or last.
        final shift = available.isEmpty ? 0 : index % available.length;
        for (final variant in [
          ...available.skip(shift),
          ...available.take(shift),
        ]) {
          if (variant.skippedScenarios[scenario.id] case final reason?) {
            scenarioResults.add(
              RunResult.skipped(scenario.id, variant.id, reason),
            );
            continue;
          }
          listener?.onRunStarted(scenario, variant);
          scenarioResults.add(await _runIsolated(scenario, variant, sampler));
        }
        results.addAll(scenarioResults);
        listener?.onScenarioFinished(scenario, scenarioResults);
      }

      return BenchmarkReport(
        startedAt: startedAt,
        finishedAt: DateTime.now(),
        environment: environment,
        configuration: configuration,
        variants: variantInfos,
        scenarios: [
          for (final scenario in scenarios)
            ScenarioInfo(
              id: scenario.id,
              title: scenario.title,
              category: scenario.category,
              description: scenario.description,
              metric: scenario.metric,
            ),
        ],
        results: results,
      );
    } finally {
      sampler.close();
    }
  }

  /// Checks that [variant] can reach the server using the expected
  /// protocol, returning the reason why not if it can't.
  Future<String?> _check(ClientVariant variant) async {
    final Client client;
    try {
      client = variant.create();
    } catch (e) {
      return 'Unable to create the client: $e';
    }
    try {
      final protocol = await _prime(client, variant, attempts: 20);
      if (protocol == variant.protocol.serverProtocol) return null;
      return 'The server received requests using $protocol rather than '
          '${variant.protocol.serverProtocol}';
    } catch (e) {
      return _describeError(e);
    } finally {
      _closeClient(client);
    }
  }

  /// Sends small requests to [origin] until one is received using the
  /// variant's protocol (or [attempts] requests have been sent), returning
  /// the protocol used by the last request.
  ///
  /// This is needed for HTTP/3, which clients discover through an "Alt-Svc"
  /// header in a response received over HTTP/1.1 or HTTP/2.
  Future<String?> _prime(
    Client client,
    ClientVariant variant, {
    int origin = 0,
    int attempts = 10,
  }) async {
    Future<String?> send() async {
      final response = await client.send(
        Request(
          'GET',
          server.uri(
            variant.protocol,
            '/bytes',
            query: {'size': '16'},
            origin: origin,
          ),
        ),
      );
      await response.stream.drain<void>();
      return response.headers['x-protocol'];
    }

    String? protocol;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        protocol = await send().timeout(_primeTimeout);
      } on TimeoutException {
        throw BenchmarkException(
          'A request to the server took longer than '
          '${_primeTimeout.inSeconds}s',
        );
      }
      if (protocol == variant.protocol.serverProtocol) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return protocol;
  }

  /// Runs [scenario] with [variant], converting uncaught asynchronous errors
  /// into a failed result.
  Future<RunResult> _runIsolated(
    Scenario scenario,
    ClientVariant variant,
    RssSampler sampler,
  ) {
    final completer = Completer<RunResult>();
    final state = _RunState();
    runZonedGuarded(
      () async {
        RunResult result;
        try {
          result = await _run(scenario, variant, sampler, state);
        } catch (e) {
          result = RunResult.failed(scenario.id, variant.id, _describeError(e));
        }
        completer.complete(result);
      },
      (error, stackTrace) {
        // The first uncaught error fails the run (see `_run`); later ones are
        // usually consequences of it.
        if (!state.fail(error) && verbose) {
          stderr.writeln(
            'Ignoring an error from ${scenario.id} (${variant.name}): $error',
          );
        }
      },
      zoneValues: state.cancellation.zoneValues,
    );
    return completer.future;
  }

  Future<RunResult> _run(
    Scenario scenario,
    ClientVariant variant,
    RssSampler sampler,
    _RunState state,
  ) async {
    final trialCount = math.min(
      configuration.trials,
      scenario.maxTrials ?? configuration.trials,
    );
    final warmupCount = math.min(
      configuration.warmup,
      scenario.maxWarmup ?? configuration.warmup,
    );
    final client = variant.create();
    final context = ScenarioContext(
      client: client,
      variant: variant,
      server: server,
    );

    // The most recent trial, which may still be running if it failed.
    Future<void>? pending;
    Future<void> runTrial(TrialRecorder recorder) {
      final trial = pending = scenario.run(context, recorder);
      // Stop waiting if the run has an uncaught error.
      return Future.any([trial.timeout(trialTimeout), state.failure]);
    }

    var succeeded = false;
    try {
      await scenario.setUp();
      for (var origin = 0; origin < scenario.origins; origin++) {
        final protocol = await _prime(client, variant, origin: origin);
        if (protocol != variant.protocol.serverProtocol) {
          throw BenchmarkException(
            'The server received requests using $protocol rather than '
            '${variant.protocol.serverProtocol}',
          );
        }
      }
      for (var i = 0; i < warmupCount; i++) {
        await runTrial(TrialRecorder());
      }

      final trials = <TrialResult>[];
      final samples = <String, List<int>>{};
      final protocols = <String, int>{};
      final notes = <String, String>{};
      for (var i = 0; i < trialCount; i++) {
        await server.resetStats();
        final baselineRss = await sampler.reset();
        final recorder = TrialRecorder();
        final stopwatch = Stopwatch()..start();
        await runTrial(recorder);
        final duration = stopwatch.elapsedMicroseconds;
        final peakRssDelta = math.max(0, await sampler.peak() - baselineRss);
        final connections = (await server.stats()).connectionsFor(
          variant.protocol,
        );

        trials.add(
          TrialResult(
            durationMicros: duration,
            operations: recorder.operations,
            bytesSent: recorder.bytesSent,
            bytesReceived: recorder.bytesReceived,
            metricValue: _metricValue(
              scenario.metric,
              recorder,
              duration,
              peakRssDelta,
            ),
            connectionsUsed: connections.used,
            connectionsOpened: connections.opened,
            peakRssDelta: peakRssDelta,
            protocols: Map.of(recorder.protocols),
            samples: {
              for (final MapEntry(:key, :value) in recorder.samples.entries)
                key: Distribution.of(value),
            },
          ),
        );
        for (final MapEntry(:key, :value) in recorder.samples.entries) {
          samples.putIfAbsent(key, () => []).addAll(value);
        }
        for (final MapEntry(:key, :value) in recorder.protocols.entries) {
          protocols[key] = (protocols[key] ?? 0) + value;
        }
        notes.addAll(recorder.notes);
      }

      succeeded = true;
      return RunResult(
        scenarioId: scenario.id,
        variantId: variant.id,
        status: RunStatus.ok,
        trials: trials,
        samples: {
          for (final MapEntry(:key, :value) in samples.entries)
            key: Distribution.of(value),
        },
        protocols: protocols,
        notes: notes,
      );
    } on TimeoutException {
      return RunResult.failed(
        scenario.id,
        variant.id,
        'A trial took longer than ${trialTimeout.inSeconds}s',
      );
    } catch (e) {
      return RunResult.failed(scenario.id, variant.id, _describeError(e));
    } finally {
      // Stop any abandoned work from starting new requests.
      state.cancellation.cancel();
      _closeClient(client);
      if (!succeeded) await _settle(client, pending);
      try {
        await scenario.tearDown();
      } catch (e) {
        if (verbose) stderr.writeln('Error tearing down ${scenario.id}: $e');
      }
    }
  }

  /// Waits, for a limited time, for the work of a failed run to stop, so
  /// that it does not overlap the next run.
  Future<void> _settle(Client client, Future<void>? pending) async {
    // Closing the client makes most outstanding requests fail quickly.
    if (pending != null) {
      await pending
          .then((_) {}, onError: (Object _) {})
          .timeout(_settleTimeout, onTimeout: () {});
    }
    // Retry, because `CupertinoClient.close` throws while requests are in
    // progress.
    _closeClient(client);
    final deadline = DateTime.now().add(_settleTimeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        if ((await server.stats()).openConnections == 0) return;
      } catch (_) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  static double _metricValue(
    Metric metric,
    TrialRecorder recorder,
    int durationMicros,
    int peakRssDelta,
  ) {
    switch (metric) {
      case Metric.requestsPerSecond:
        return recorder.operations / (durationMicros / 1e6);
      case Metric.throughput:
        // Bytes per microsecond is the same as megabytes per second.
        return (recorder.bytesSent + recorder.bytesReceived) / durationMicros;
      case Metric.peakMemory:
        return peakRssDelta.toDouble();
      case Metric.bufferedBytes:
        return recorder.value ??
            (throw StateError('The scenario did not record a value'));
      case Metric.latency || Metric.eventLatency || Metric.cancelLatency:
        final samples = recorder.samples[metric.sample];
        if (samples == null || samples.isEmpty) {
          throw StateError('No "${metric.sample}" samples were recorded');
        }
        return median(samples);
    }
  }

  static void _closeClient(Client client) {
    try {
      client.close();
    } catch (_) {
      // For example, `CupertinoClient.close` throws if requests are still in
      // progress, which happens after a timeout.
    }
  }

  static String _describeError(Object error) {
    // Some errors explain themselves on later lines (e.g. the reason for a
    // `HandshakeException`), so join the lines rather than keeping the first.
    final description = error
        .toString()
        .trim()
        .split(RegExp(r'\s*\n\s*'))
        .join(' ');
    return description.length > 300
        ? '${description.substring(0, 300)}…'
        : description;
  }
}

/// The state of a single run of a scenario with a client variant.
class _RunState {
  _RunState() {
    // `failure` is only listened to while a trial is running.
    _failure.future.ignore();
  }

  /// Cancelled when the run ends, so that abandoned work stops.
  final cancellation = Cancellation();

  final _failure = Completer<Never>();
  var _failed = false;

  /// Completes with an error if the run has an uncaught error.
  Future<Never> get failure => _failure.future;

  /// Fails the run because of the uncaught [error], returning false if it
  /// had already failed.
  bool fail(Object error) {
    if (_failed) return false;
    _failed = true;
    cancellation.cancel();
    _failure.completeError(_UncaughtError(error));
    return true;
  }
}

class _UncaughtError {
  _UncaughtError(this.error);

  final Object error;

  @override
  String toString() => 'Uncaught error: $error';
}
