// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math' as math;

import 'environment.dart';
import 'metric.dart';
import 'protocol.dart';
import 'stats.dart';

/// The outcome of running a scenario with a client variant.
enum RunStatus {
  /// All trials completed successfully.
  ok,

  /// A trial failed or timed out.
  failed,

  /// The scenario does not apply to the client variant.
  skipped,
}

Map<String, int> _intMap(Object? json) => {
  for (final MapEntry(:key, :value)
      in (json as Map<String, Object?>? ?? const {}).entries)
    key: value as int,
};

Map<String, Distribution> _distributionMap(Object? json) => {
  for (final MapEntry(:key, :value)
      in (json as Map<String, Object?>? ?? const {}).entries)
    key: Distribution.fromJson(value as Map<String, Object?>),
};

/// Measurements from one trial of a scenario.
class TrialResult {
  TrialResult({
    required this.durationMicros,
    required this.operations,
    required this.bytesSent,
    required this.bytesReceived,
    required this.metricValue,
    required this.connectionsUsed,
    required this.connectionsOpened,
    required this.peakRssDelta,
    required this.protocols,
    required this.samples,
  });

  factory TrialResult.fromJson(Map<String, Object?> json) => TrialResult(
    durationMicros: json['durationMicros'] as int,
    operations: json['operations'] as int,
    bytesSent: json['bytesSent'] as int,
    bytesReceived: json['bytesReceived'] as int,
    metricValue: (json['metricValue'] as num).toDouble(),
    connectionsUsed: json['connectionsUsed'] as int,
    connectionsOpened: json['connectionsOpened'] as int,
    peakRssDelta: json['peakRssDelta'] as int,
    protocols: _intMap(json['protocols']),
    samples: _distributionMap(json['samples']),
  );

  /// The wall-clock duration of the trial.
  final int durationMicros;

  /// The number of operations (usually requests) completed.
  final int operations;

  /// The number of request body bytes sent.
  final int bytesSent;

  /// The number of response body bytes received.
  final int bytesReceived;

  /// The value of the scenario's primary [Metric].
  final double metricValue;

  /// The number of distinct connections that served requests.
  final int connectionsUsed;

  /// The number of new connections accepted by the server.
  final int connectionsOpened;

  /// The growth of the process's resident set size, in bytes.
  final int peakRssDelta;

  /// The number of requests that the server received with each protocol.
  final Map<String, int> protocols;

  /// Summaries of the samples (e.g. "latency") recorded during the trial.
  final Map<String, Distribution> samples;

  double get requestsPerSecond => operations / (durationMicros / 1e6);

  /// Payload throughput in MB/s (bytes per microsecond).
  double get megabytesPerSecond => (bytesSent + bytesReceived) / durationMicros;

  Map<String, Object?> toJson() => {
    'durationMicros': durationMicros,
    'operations': operations,
    'bytesSent': bytesSent,
    'bytesReceived': bytesReceived,
    'metricValue': metricValue,
    'connectionsUsed': connectionsUsed,
    'connectionsOpened': connectionsOpened,
    'peakRssDelta': peakRssDelta,
    'protocols': protocols,
    'samples': {
      for (final MapEntry(:key, :value) in samples.entries) key: value.toJson(),
    },
  };
}

/// The result of running one scenario with one client variant.
class RunResult {
  RunResult({
    required this.scenarioId,
    required this.variantId,
    required this.status,
    this.message,
    this.trials = const [],
    this.samples = const {},
    this.protocols = const {},
    this.notes = const {},
  });

  factory RunResult.failed(
    String scenarioId,
    String variantId,
    String message,
  ) => RunResult(
    scenarioId: scenarioId,
    variantId: variantId,
    status: RunStatus.failed,
    message: message,
  );

  factory RunResult.skipped(
    String scenarioId,
    String variantId,
    String reason,
  ) => RunResult(
    scenarioId: scenarioId,
    variantId: variantId,
    status: RunStatus.skipped,
    message: reason,
  );

  factory RunResult.fromJson(Map<String, Object?> json) => RunResult(
    scenarioId: json['scenario'] as String,
    variantId: json['variant'] as String,
    status: RunStatus.values.byName(json['status'] as String),
    message: json['message'] as String?,
    trials: [
      for (final trial in json['trials'] as List<Object?>? ?? const [])
        TrialResult.fromJson(trial as Map<String, Object?>),
    ],
    samples: _distributionMap(json['samples']),
    protocols: _intMap(json['protocols']),
    notes: {
      for (final MapEntry(:key, :value)
          in (json['notes'] as Map<String, Object?>? ?? const {}).entries)
        key: value as String,
    },
  );

  final String scenarioId;
  final String variantId;
  final RunStatus status;

  /// Why the run failed or was skipped.
  final String? message;

  /// The measured trials (excluding warmup trials).
  final List<TrialResult> trials;

  /// Summaries of the samples recorded across all trials.
  final Map<String, Distribution> samples;

  /// The number of requests that the server received with each protocol,
  /// across all trials.
  final Map<String, int> protocols;

  /// Observations about the run, e.g. whether the client decompressed the
  /// response.
  final Map<String, String> notes;

  bool get isOk => status == RunStatus.ok && trials.isNotEmpty;

  /// The values of the primary metric for each trial.
  List<double> get metricValues => [for (final t in trials) t.metricValue];

  /// The distribution of the primary metric across trials.
  late final Distribution? metric = trials.isEmpty
      ? null
      : Distribution.of(metricValues);

  /// The median requests per second across trials.
  double? get requestsPerSecond =>
      trials.isEmpty ? null : median(trials.map((t) => t.requestsPerSecond));

  /// The median payload throughput (MB/s) across trials.
  double? get megabytesPerSecond =>
      trials.isEmpty ? null : median(trials.map((t) => t.megabytesPerSecond));

  /// The maximum number of connections used in a trial.
  int? get connectionsUsed => trials.isEmpty
      ? null
      : trials.map((t) => t.connectionsUsed).reduce(math.max);

  /// The median, across trials, of the peak growth of the resident set size
  /// during each trial.
  ///
  /// The median is used because single trials sometimes show large, unrelated
  /// growth (e.g. when the Dart VM grows its heap).
  int? get peakRssDelta =>
      trials.isEmpty ? null : median(trials.map((t) => t.peakRssDelta)).round();

  /// The fraction of requests that the server received using [protocol],
  /// or `null` if no requests were recorded.
  double? protocolShare(String protocol) {
    final total = protocols.values.fold(0, (a, b) => a + b);
    return total == 0 ? null : (protocols[protocol] ?? 0) / total;
  }

  Map<String, Object?> toJson() => {
    'scenario': scenarioId,
    'variant': variantId,
    'status': status.name,
    if (message != null) 'message': message,
    if (trials.isNotEmpty) ...{
      'metric': metric!.toJson(),
      'trials': [for (final trial in trials) trial.toJson()],
      'samples': {
        for (final MapEntry(:key, :value) in samples.entries)
          key: value.toJson(),
      },
      'protocols': protocols,
    },
    if (notes.isNotEmpty) 'notes': notes,
  };
}

/// Describes a client variant included in a benchmark run.
class VariantInfo {
  VariantInfo({
    required this.id,
    required this.client,
    required this.protocol,
    this.unavailableReason,
  });

  factory VariantInfo.fromJson(Map<String, Object?> json) => VariantInfo(
    id: json['id'] as String,
    client: json['client'] as String,
    protocol: HttpProtocol.fromId(json['protocol'] as String),
    unavailableReason: json['unavailableReason'] as String?,
  );

  final String id;

  /// The name of the client implementation, e.g. "IOClient".
  final String client;

  final HttpProtocol protocol;

  /// Why the variant could not be benchmarked, or `null` if it was.
  final String? unavailableReason;

  bool get available => unavailableReason == null;

  /// A short human-readable name, e.g. "IOClient h1".
  String get name => '$client ${protocol.id}';

  Map<String, Object?> toJson() => {
    'id': id,
    'client': client,
    'protocol': protocol.id,
    if (unavailableReason != null) 'unavailableReason': unavailableReason,
  };
}

/// Describes a scenario included in a benchmark run.
class ScenarioInfo {
  ScenarioInfo({
    required this.id,
    required this.title,
    required this.category,
    required this.description,
    required this.metric,
  });

  factory ScenarioInfo.fromJson(Map<String, Object?> json) => ScenarioInfo(
    id: json['id'] as String,
    title: json['title'] as String,
    category: json['category'] as String,
    description: json['description'] as String,
    metric: Metric.values.byName(json['metric'] as String),
  );

  final String id;
  final String title;
  final String category;
  final String description;
  final Metric metric;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'category': category,
    'description': description,
    'metric': metric.name,
  };
}

/// The settings used for a benchmark run.
class RunConfiguration {
  RunConfiguration({
    required this.trials,
    required this.warmup,
    required this.quick,
    required this.httpProfiling,
  });

  factory RunConfiguration.fromJson(Map<String, Object?> json) =>
      RunConfiguration(
        trials: json['trials'] as int,
        warmup: json['warmup'] as int,
        quick: json['quick'] as bool,
        httpProfiling: json['httpProfiling'] as bool,
      );

  /// The number of measured trials per scenario (some scenarios run fewer).
  final int trials;

  /// The number of warmup trials per scenario (some scenarios run fewer).
  final int warmup;

  /// Whether reduced request counts and payload sizes were used.
  final bool quick;

  /// Whether HTTP profiling (as used by the DevTools network view) was
  /// enabled.
  final bool httpProfiling;

  Map<String, Object?> toJson() => {
    'trials': trials,
    'warmup': warmup,
    'quick': quick,
    'httpProfiling': httpProfiling,
  };
}

/// The complete results of a benchmark run.
class BenchmarkReport {
  BenchmarkReport({
    required this.startedAt,
    required this.finishedAt,
    required this.environment,
    required this.configuration,
    required this.variants,
    required this.scenarios,
    required this.results,
  });

  factory BenchmarkReport.fromJson(Map<String, Object?> json) {
    final version = json['schemaVersion'];
    if (version != schemaVersion) {
      throw FormatException(
        'Unsupported benchmark results version: $version '
        '(expected $schemaVersion)',
      );
    }
    return BenchmarkReport(
      startedAt: DateTime.parse(json['startedAt'] as String),
      finishedAt: DateTime.parse(json['finishedAt'] as String),
      environment: Environment.fromJson(
        json['environment'] as Map<String, Object?>,
      ),
      configuration: RunConfiguration.fromJson(
        json['configuration'] as Map<String, Object?>,
      ),
      variants: [
        for (final variant in json['variants'] as List<Object?>)
          VariantInfo.fromJson(variant as Map<String, Object?>),
      ],
      scenarios: [
        for (final scenario in json['scenarios'] as List<Object?>)
          ScenarioInfo.fromJson(scenario as Map<String, Object?>),
      ],
      results: [
        for (final result in json['results'] as List<Object?>)
          RunResult.fromJson(result as Map<String, Object?>),
      ],
    );
  }

  /// The version of the JSON format produced by [toJson].
  static const schemaVersion = 1;

  final DateTime startedAt;
  final DateTime finishedAt;
  final Environment environment;
  final RunConfiguration configuration;
  final List<VariantInfo> variants;
  final List<ScenarioInfo> scenarios;
  final List<RunResult> results;

  /// The variants that could be benchmarked.
  List<VariantInfo> get availableVariants => [
    for (final variant in variants)
      if (variant.available) variant,
  ];

  /// The scenario categories, in the order in which they were run.
  List<String> get categories =>
      {for (final scenario in scenarios) scenario.category}.toList();

  VariantInfo variant(String id) => variants.firstWhere((v) => v.id == id);

  ScenarioInfo scenario(String id) => scenarios.firstWhere((s) => s.id == id);

  /// The results of the scenario with the given [scenarioId].
  List<RunResult> resultsFor(String scenarioId) => [
    for (final result in results)
      if (result.scenarioId == scenarioId) result,
  ];

  RunResult? result(String scenarioId, String variantId) {
    for (final result in results) {
      if (result.scenarioId == scenarioId && result.variantId == variantId) {
        return result;
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt.toIso8601String(),
    'environment': environment.toJson(),
    'configuration': configuration.toJson(),
    'variants': [for (final variant in variants) variant.toJson()],
    'scenarios': [for (final scenario in scenarios) scenario.toJson()],
    'results': [for (final result in results) result.toJson()],
  };
}
