// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math' as math;

import '../format.dart';
import '../metric.dart';
import '../results.dart';

/// The fraction of requests that must use the expected protocol for a run
/// to be considered representative of that protocol.
const protocolShareThreshold = 0.99;

/// Human-readable names for the samples recorded by scenarios.
const sampleLabels = {
  'latency': 'Latency',
  'ttfb': 'TTFB',
  'event': 'Event delay',
  'cancel': 'Cancel time',
  'recovery': 'Cancel + next',
};

/// One client variant's result for a scenario, with its relative ranking.
class RankedResult {
  RankedResult({
    required this.variant,
    required this.result,
    required this.ratio,
  });

  final VariantInfo variant;
  final RunResult result;

  /// The variant's performance relative to the best variant (1 is best), or
  /// `null` if the run did not succeed.
  final double? ratio;

  /// The fraction of requests received using the variant's protocol.
  double? get protocolShare =>
      result.protocolShare(variant.protocol.serverProtocol);

  /// Whether a significant fraction of requests used an unexpected protocol.
  bool get protocolMismatch =>
      protocolShare != null && protocolShare! < protocolShareThreshold;

  /// Describes the protocols used, e.g. "HTTP/2.0 88%, HTTP/3.0 12%".
  String get protocolDescription {
    final total = result.protocols.values.fold(0, (a, b) => a + b);
    final entries = result.protocols.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final MapEntry(:key, :value) in entries)
        '$key ${formatPercent(value / total)}',
    ].join(', ');
  }
}

/// The results of a scenario, ranked from best to worst.
class ScenarioSummary {
  ScenarioSummary(this.report, this.scenario);

  final BenchmarkReport report;
  final ScenarioInfo scenario;

  Metric get metric => scenario.metric;

  /// The samples whose percentiles best describe the scenario.
  String get sampleName => metric.sample ?? 'latency';

  /// The results, ordered from best to worst, followed by failed and skipped
  /// runs.
  late final List<RankedResult> ranked = () {
    final results = report.resultsFor(scenario.id);
    final ok = [
      for (final result in results)
        if (result.isOk) result,
    ];
    double value(RunResult result) => result.metric!.p50;
    final best = ok.isEmpty
        ? null
        : ok.map(value).reduce((a, b) => metric.isBetter(a, b) ? a : b);
    ok.sort((a, b) {
      if (value(a) == value(b)) return 0;
      return metric.isBetter(value(a), value(b)) ? -1 : 1;
    });
    return [
      for (final result in ok)
        RankedResult(
          variant: report.variant(result.variantId),
          result: result,
          ratio: metric.ratio(value(result), best!),
        ),
      for (final result in results)
        if (!result.isOk)
          RankedResult(
            variant: report.variant(result.variantId),
            result: result,
            ratio: null,
          ),
    ];
  }();
}

/// A client variant's performance across all scenarios.
class VariantScore {
  VariantScore({
    required this.variant,
    required this.ratios,
    required this.failures,
  });

  final VariantInfo variant;

  /// The variant's relative performance in each scored scenario, keyed by
  /// scenario ID.
  ///
  /// See [scoreVariants] for which scenarios are scored.
  final Map<String, double> ratios;

  /// The number of scenarios in which the variant failed.
  final int failures;

  /// The number of scored scenarios in which the variant was the best.
  int get wins => ratios.values.where((ratio) => ratio == 1).length;

  /// The geometric mean of [ratios] (each clamped to at least
  /// [minimumRatio]), or `null` if there are none.
  double? get score => ratios.isEmpty
      ? null
      : math.exp(
          ratios.values
                  .map((ratio) => math.log(math.max(ratio, minimumRatio)))
                  .reduce((a, b) => a + b) /
              ratios.length,
        );

  /// The smallest ratio used when computing [score], so that a single
  /// extreme result cannot dominate it.
  static const minimumRatio = 0.01;
}

/// Scores each available variant, ordered from best to worst.
///
/// So that scores are comparable, they only include scenarios that every
/// available variant completed using its expected protocol: a variant that
/// fails a demanding scenario should not score better than one that
/// completes it slowly. Scores summarize speed, so scenarios that measure
/// memory use are not included (but their failures are counted).
List<VariantScore> scoreVariants(BenchmarkReport report) {
  final variants = report.availableVariants;
  final ratios = {
    for (final variant in variants) variant.id: <String, double>{},
  };
  final failures = {for (final variant in variants) variant.id: 0};
  for (final scenario in report.scenarios) {
    final summary = ScenarioSummary(report, scenario);
    for (final ranked in summary.ranked) {
      if (ranked.result.status == RunStatus.failed) {
        failures[ranked.variant.id] = (failures[ranked.variant.id] ?? 0) + 1;
      }
    }
    if (scenario.metric.measuresMemory || variants.length < 2) continue;
    final valid = {
      for (final ranked in summary.ranked)
        if (ranked.ratio != null && !ranked.protocolMismatch)
          ranked.variant.id: ranked.ratio!,
    };
    if (!variants.every((variant) => valid.containsKey(variant.id))) continue;
    for (final MapEntry(key: id, value: ratio) in valid.entries) {
      ratios[id]?[scenario.id] = ratio;
    }
  }
  return [
    for (final variant in variants)
      VariantScore(
        variant: variant,
        ratios: ratios[variant.id]!,
        failures: failures[variant.id]!,
      ),
  ]..sort((a, b) => (b.score ?? -1).compareTo(a.score ?? -1));
}

/// Describes the scenarios that [scores] (from [scoreVariants]) cover.
String scoreBasis(BenchmarkReport report, List<VariantScore> scores) {
  final speed = report.scenarios.where((s) => !s.metric.measuresMemory).length;
  final scored = scores.isEmpty ? 0 : scores.first.ratios.length;
  return 'Scores cover the $scored of $speed speed scenarios that every '
      'client completed using its expected protocol.';
}
