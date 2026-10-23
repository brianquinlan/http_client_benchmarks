// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math' as math;

import 'environment.dart';
import 'format.dart';
import 'metric.dart';
import 'reporters/console_reporter.dart' show formatTable;
import 'results.dart';
import 'stats.dart';

/// The change in a scenario's primary metric between two benchmark runs.
class Comparison {
  Comparison({
    required this.scenario,
    required this.variant,
    required this.baseline,
    required this.candidate,
    required this.pValue,
    this.adjustedPValue,
  });

  final ScenarioInfo scenario;
  final VariantInfo variant;

  /// The per-trial values of the metric in the baseline run.
  final List<double> baseline;

  /// The per-trial values of the metric in the candidate run.
  final List<double> candidate;

  /// The two-sided p-value of a Mann-Whitney U test comparing [baseline]
  /// and [candidate].
  final double pValue;

  /// [pValue] adjusted for multiple comparisons, if requested.
  final double? adjustedPValue;

  Metric get metric => scenario.metric;

  double get baselineMedian => median(baseline);
  double get candidateMedian => median(candidate);

  /// The relative change in the median, e.g. 0.1 for a 10% increase.
  ///
  /// Values below the metric's noise floor are treated as equal to it, so
  /// that noise in small values does not appear as a large relative change.
  double get change {
    final before = math.max(baselineMedian, metric.noiseFloor);
    final after = math.max(candidateMedian, metric.noiseFloor);
    return before == 0 ? 0 : (after - before) / before;
  }

  /// Whether there are enough trials for any difference to be statistically
  /// significant at level [alpha].
  bool canBeSignificant(double alpha) =>
      minimumMannWhitneyPValue(baseline.length, candidate.length) < alpha;

  /// The p-value used to decide whether the change is significant:
  /// [adjustedPValue] if it is available, otherwise [pValue].
  double get effectivePValue => adjustedPValue ?? pValue;

  /// Whether the difference is statistically significant at level [alpha].
  bool isSignificant(double alpha) => effectivePValue < alpha;

  /// Whether the candidate performed better than the baseline.
  bool get improved => metric.isBetter(candidateMedian, baselineMedian);

  /// Classifies the change at significance level [alpha].
  ///
  /// Changes smaller than [threshold] (a fraction, e.g. 0.05 for 5%) are
  /// considered unchanged even if they are statistically significant.
  Verdict verdict({double alpha = 0.05, double threshold = 0}) {
    if (!canBeSignificant(alpha)) return Verdict.inconclusive;
    if (!isSignificant(alpha) || change.abs() < threshold) {
      return Verdict.unchanged;
    }
    return improved ? Verdict.improved : Verdict.regressed;
  }

  Comparison _withAdjustedPValue(double adjusted) => Comparison(
    scenario: scenario,
    variant: variant,
    baseline: baseline,
    candidate: candidate,
    pValue: pValue,
    adjustedPValue: adjusted,
  );
}

/// The outcome of a [Comparison].
enum Verdict {
  improved,
  regressed,

  /// The change was not statistically significant or was smaller than the
  /// threshold.
  unchanged,

  /// There were too few trials for any change to be significant.
  inconclusive,
}

/// Compares the results that [baseline] and [candidate] have in common.
///
/// Scenarios whose definitions differ between the reports (see
/// [compatibilityWarnings]) are not compared. If [controlFalseDiscoveryRate]
/// is true, the p-values are adjusted for the number of comparisons using
/// the Benjamini-Hochberg procedure.
///
/// Throws a [FormatException] if the reports were produced with
/// incompatible configurations.
List<Comparison> compareReports(
  BenchmarkReport baseline,
  BenchmarkReport candidate, {
  bool controlFalseDiscoveryRate = false,
}) {
  if (baseline.configuration.quick != candidate.configuration.quick) {
    throw const FormatException(
      'Only one of the reports was produced in quick mode, so the payload '
      'sizes differ.',
    );
  }
  final comparisons = <Comparison>[];
  for (final scenario in candidate.scenarios) {
    final previousScenario = baseline.scenarios
        .where((s) => s.id == scenario.id)
        .firstOrNull;
    if (previousScenario == null ||
        previousScenario.metric != scenario.metric ||
        previousScenario.title != scenario.title) {
      continue;
    }
    for (final result in candidate.resultsFor(scenario.id)) {
      final previous = baseline.result(scenario.id, result.variantId);
      if (previous == null || !previous.isOk || !result.isOk) continue;
      comparisons.add(
        Comparison(
          scenario: scenario,
          variant: candidate.variant(result.variantId),
          baseline: previous.metricValues,
          candidate: result.metricValues,
          pValue: mannWhitneyU(
            previous.metricValues,
            result.metricValues,
          ).pValue,
        ),
      );
    }
  }
  if (!controlFalseDiscoveryRate || comparisons.isEmpty) return comparisons;
  final adjusted = adjustForFalseDiscoveryRate([
    for (final comparison in comparisons) comparison.pValue,
  ]);
  return [
    for (var i = 0; i < comparisons.length; i++)
      comparisons[i]._withAdjustedPValue(adjusted[i]),
  ];
}

/// Describes differences between the ways that [baseline] and [candidate]
/// were produced, which could explain differences in their results.
List<String> compatibilityWarnings(
  BenchmarkReport baseline,
  BenchmarkReport candidate,
) {
  final before = baseline.environment;
  final after = candidate.environment;
  String versions(Environment e) => [
    'Dart ${e.dartVersion} (${e.compilationMode})',
    if (e.goVersion != null) 'Go ${e.goVersion!.replaceFirst('go', '')}',
    if (e.quicGoVersion != null) 'quic-go ${e.quicGoVersion}',
  ].join(' · ');
  final changedScenarios = [
    for (final scenario in candidate.scenarios)
      if (baseline.scenarios.any(
        (s) =>
            s.id == scenario.id &&
            (s.title != scenario.title || s.metric != scenario.metric),
      ))
        scenario.id,
  ];
  return [
    if (before.machine != after.machine)
      'The reports were produced on different machines '
          '(${before.machine} and ${after.machine}).',
    if (versions(before) != versions(after))
      'The reports were produced with different software '
          '(${versions(before)} and ${versions(after)}).',
    if (baseline.configuration.httpProfiling !=
        candidate.configuration.httpProfiling)
      'HTTP profiling, which slows down dart:io clients, was only enabled '
          'for one of the reports.',
    if (changedScenarios.isNotEmpty)
      'These scenarios were changed between the reports, so they were not '
          'compared: ${changedScenarios.join(', ')}.',
  ];
}

String _change(Comparison comparison, Verdict verdict) => switch (verdict) {
  Verdict.inconclusive => '?',
  Verdict.unchanged => '~',
  _ =>
    '${comparison.change >= 0 ? '+' : ''}'
        '${formatPercent(comparison.change, decimals: 1)}',
};

/// The smallest number of trials per run for which a change can be
/// significant at level [alpha].
int _minimumTrials(double alpha) {
  var trials = 1;
  while (minimumMannWhitneyPValue(trials, trials) >= alpha) {
    trials++;
  }
  return trials;
}

List<String> _footnotes(
  List<Comparison> comparisons,
  List<Verdict> verdicts, {
  required double alpha,
  required double threshold,
}) {
  int count(Verdict verdict) => verdicts.where((v) => v == verdict).length;
  final adjusted = comparisons.any((c) => c.adjustedPValue != null);
  final inconclusive = count(Verdict.inconclusive);
  return [
    '${count(Verdict.improved)} improved, ${count(Verdict.regressed)} '
        'regressed, ${count(Verdict.unchanged)} unchanged'
        '${inconclusive == 0 ? '' : ', $inconclusive inconclusive'}.',
    '"~" marks changes that are not statistically significant (p ≥ $alpha, '
        'two-sided Mann-Whitney U test on per-trial values)'
        '${threshold > 0 ? ' or are smaller than '
                  '${formatPercent(threshold, decimals: 1)}' : ''}.',
    if (inconclusive > 0)
      '"?" marks results with too few trials for any change to be '
          'significant; use at least ${_minimumTrials(alpha)} trials per run.',
    if (adjusted)
      'p-values are adjusted for ${comparisons.length} comparisons '
          '(Benjamini-Hochberg).'
    else if (comparisons.length * alpha >= 1)
      'With ${comparisons.length} comparisons, about '
          '${(comparisons.length * alpha).round()} significant changes are '
          'expected by chance alone; re-run to confirm changes or use --fdr.',
  ];
}

/// Formats [comparisons] as a table for a terminal.
String formatComparisons(
  List<Comparison> comparisons, {
  double alpha = 0.05,
  double threshold = 0,
  bool color = false,
  List<String> warnings = const [],
}) {
  String style(String text, String code) =>
      color ? '\x1B[${code}m$text\x1B[0m' : text;
  final verdicts = [
    for (final comparison in comparisons)
      comparison.verdict(alpha: alpha, threshold: threshold),
  ];
  final rows = <List<String>>[
    ['Scenario', 'Client', 'Metric', 'Baseline', 'Candidate', 'Change', 'p'],
    for (final (i, comparison) in comparisons.indexed)
      [
        comparison.scenario.id,
        comparison.variant.name,
        comparison.metric.label,
        formatMetric(comparison.metric, comparison.baselineMedian),
        formatMetric(comparison.metric, comparison.candidateMedian),
        switch (verdicts[i]) {
          Verdict.improved => style(_change(comparison, verdicts[i]), '32'),
          Verdict.regressed => style(_change(comparison, verdicts[i]), '31'),
          final verdict => _change(comparison, verdict),
        },
        comparison.effectivePValue.toStringAsFixed(3),
      ],
  ];
  final buffer = StringBuffer();
  for (final warning in warnings) {
    buffer.writeln(style('Warning: $warning', '33'));
  }
  if (warnings.isNotEmpty) buffer.writeln();
  buffer.write(formatTable(rows, rightAligned: {3, 4, 5, 6}));
  buffer.writeln();
  for (final footnote in _footnotes(
    comparisons,
    verdicts,
    alpha: alpha,
    threshold: threshold,
  )) {
    buffer.writeln(footnote);
  }
  return buffer.toString();
}

/// Formats [comparisons] as a Markdown table.
String formatComparisonsMarkdown(
  List<Comparison> comparisons, {
  double alpha = 0.05,
  double threshold = 0,
  List<String> warnings = const [],
}) {
  final verdicts = [
    for (final comparison in comparisons)
      comparison.verdict(alpha: alpha, threshold: threshold),
  ];
  final buffer = StringBuffer();
  for (final warning in warnings) {
    buffer.writeln('> [!WARNING]\n> $warning\n');
  }
  buffer
    ..writeln(
      '| Scenario | Client | Metric | Baseline | Candidate | Change | p |',
    )
    ..writeln('| --- | --- | --- | ---: | ---: | ---: | ---: |');
  for (var i = 0; i < comparisons.length; i++) {
    final comparison = comparisons[i];
    final change = _change(comparison, verdicts[i]);
    final decorated = switch (verdicts[i]) {
      Verdict.improved => '🟢 $change',
      Verdict.regressed => '🔴 $change',
      _ => change,
    };
    buffer.writeln(
      '| `${comparison.scenario.id}` | ${comparison.variant.name} | '
      '${comparison.metric.label} | '
      '${formatMetric(comparison.metric, comparison.baselineMedian)} | '
      '${formatMetric(comparison.metric, comparison.candidateMedian)} | '
      '$decorated | ${comparison.effectivePValue.toStringAsFixed(3)} |',
    );
  }
  buffer.writeln();
  for (final footnote in _footnotes(
    comparisons,
    verdicts,
    alpha: alpha,
    threshold: threshold,
  )) {
    buffer.writeln('- ${footnote.replaceAll('--fdr', '`--fdr`')}');
  }
  return buffer.toString();
}
