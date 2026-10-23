// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart';

import 'clients.dart';
import 'metric.dart';
import 'server.dart';

/// Thrown when a scenario observes an incorrect response.
class BenchmarkException implements Exception {
  BenchmarkException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A benchmark workload.
///
/// The runner calls [setUp], then calls [run] once for each warmup trial and
/// each measured trial, and finally calls [tearDown]. All trials of a run
/// share one [Client], so connections established in earlier trials may be
/// reused.
abstract class Scenario {
  /// A unique, stable identifier, e.g. "get-concurrent-128".
  String get id;

  /// A short description of the workload, e.g. "128 concurrent GETs".
  String get title;

  /// The group that the scenario belongs to, e.g. "Downloads".
  String get category;

  /// A longer description of the workload and what it measures.
  String get description;

  /// The primary measurement used to compare clients.
  Metric get metric;

  /// The number of server origins that the scenario sends requests to.
  int get origins => 1;

  /// The maximum number of measured trials, for slow scenarios.
  int? get maxTrials => null;

  /// The maximum number of warmup trials, for slow scenarios.
  int? get maxWarmup => null;

  /// Allocates resources (e.g. request bodies) used by every trial.
  Future<void> setUp() async {}

  /// Runs one trial, recording measurements in [recorder].
  Future<void> run(ScenarioContext context, TrialRecorder recorder);

  /// Releases the resources allocated by [setUp].
  Future<void> tearDown() async {}
}

/// The environment in which a [Scenario] runs.
class ScenarioContext {
  ScenarioContext({
    required this.client,
    required this.variant,
    required this.server,
  });

  /// The client being benchmarked.
  final Client client;

  /// The configuration of [client].
  final ClientVariant variant;

  final BenchmarkServer server;

  /// The URL of [path] on the benchmark server, using the client's protocol.
  Uri uri(String path, {Map<String, Object>? query, int origin = 0}) =>
      server.uri(
        variant.protocol,
        path,
        query: query?.map((key, value) => MapEntry(key, '$value')),
        origin: origin,
      );
}

/// Signals that the work of a run should stop, e.g. because a trial timed
/// out.
///
/// The runner makes a cancellation available to scenarios through
/// [Cancellation.current]; [runConcurrently] and [timedSend] stop starting
/// new requests once it has been cancelled.
class Cancellation {
  static final _key = Object();

  /// The cancellation of the run that the current code belongs to, if any.
  static Cancellation? get current => Zone.current[_key] as Cancellation?;

  /// Zone values that make this the [current] cancellation.
  Map<Object, Object?> get zoneValues => {_key: this};

  bool get isCancelled => _cancelled;
  bool _cancelled = false;

  void cancel() => _cancelled = true;
}

/// Throws a [BenchmarkException] if the current run has been cancelled.
void checkNotCancelled() {
  if (Cancellation.current?.isCancelled ?? false) {
    throw BenchmarkException('The run was cancelled');
  }
}

var _nextId = 0;

/// Returns a string that identifies a request to the server's progress
/// counters (see [BenchmarkServer.progress]).
String uniqueId() => '${DateTime.now().microsecondsSinceEpoch}-${_nextId++}';

/// Collects the measurements made during one trial.
class TrialRecorder {
  /// Timing samples in microseconds, keyed by name (e.g. "latency", "ttfb").
  final samples = <String, List<int>>{};

  /// The number of operations (usually requests) completed.
  int operations = 0;

  /// The number of request body bytes sent.
  int bytesSent = 0;

  /// The number of response body bytes received.
  int bytesReceived = 0;

  /// The value of the scenario's metric, for metrics that are measured
  /// directly by the scenario (e.g. [Metric.bufferedBytes]).
  double? value;

  /// The number of responses received with each protocol, as reported by
  /// the server.
  final protocols = <String, int>{};

  /// Observations about the client's behavior.
  final notes = <String, String>{};

  void addSample(String name, int microseconds) =>
      samples.putIfAbsent(name, () => []).add(microseconds);

  /// Records the protocol that the server used to receive the request that
  /// produced [response].
  void addResponse(BaseResponse response) {
    final protocol = response.headers['x-protocol'] ?? 'unknown';
    protocols[protocol] = (protocols[protocol] ?? 0) + 1;
  }
}

/// Throws a [BenchmarkException] if [response] is not successful.
void checkResponse(BaseRequest request, BaseResponse response) {
  if (response.statusCode != 200) {
    throw BenchmarkException(
      '${request.method} ${request.url} failed with status '
      '${response.statusCode} ${response.reasonPhrase ?? ''}',
    );
  }
}

/// Sends [request] and reads the entire response body.
///
/// Records the time until the response headers were received ("ttfb") and
/// the time until the body was fully read ("latency") unless [record] is
/// false. Returns the response and, if [keepBody] is true, its body.
Future<({BaseResponse response, Uint8List? body})> timedSend(
  ScenarioContext context,
  TrialRecorder recorder,
  BaseRequest request, {
  int? expectedLength,
  int requestBytes = 0,
  bool keepBody = false,
  bool record = true,
  bool countReceived = true,
}) async {
  checkNotCancelled();
  final stopwatch = Stopwatch()..start();
  final response = await context.client.send(request);
  final ttfb = stopwatch.elapsedMicroseconds;
  final builder = keepBody ? BytesBuilder(copy: false) : null;
  var length = 0;
  await for (final chunk in response.stream) {
    length += chunk.length;
    builder?.add(chunk);
  }
  final elapsed = stopwatch.elapsedMicroseconds;

  checkResponse(request, response);
  if (expectedLength != null && length != expectedLength) {
    throw BenchmarkException(
      '${request.method} ${request.url}: expected $expectedLength bytes, '
      'received $length',
    );
  }
  recorder
    ..operations += 1
    ..bytesSent += requestBytes
    ..addResponse(response);
  if (countReceived) recorder.bytesReceived += length;
  if (record) {
    recorder
      ..addSample('ttfb', ttfb)
      ..addSample('latency', elapsed);
  }
  return (response: response, body: builder?.takeBytes());
}

/// Runs [operation] [count] times, with at most [concurrency] operations in
/// progress at any time.
///
/// If [minDuration] is given then operations continue to be started (with
/// increasing indices) until at least [count] operations have been started
/// and [minDuration] has elapsed, so that short workloads are measured for
/// long enough to be stable.
///
/// Completes with the first error, if any. Stops starting operations if the
/// current run is cancelled (see [Cancellation]).
Future<void> runConcurrently(
  int count,
  int concurrency,
  Future<void> Function(int index) operation, {
  Duration minDuration = Duration.zero,
}) async {
  final cancellation = Cancellation.current;
  final stopwatch = Stopwatch()..start();
  var next = 0;
  bool more() =>
      !(cancellation?.isCancelled ?? false) &&
      (next < count || stopwatch.elapsed < minDuration);
  Future<void> worker() async {
    while (more()) {
      await operation(next++);
    }
  }

  await Future.wait([
    for (var i = 0; i < math.min(count, concurrency); i++) worker(),
  ], eagerError: true);
}
