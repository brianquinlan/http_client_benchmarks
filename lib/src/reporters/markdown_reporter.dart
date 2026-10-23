// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../format.dart';
import '../results.dart';
import 'summary.dart';

String _escape(String text) =>
    text.replaceAll('|', r'\|').replaceAll('\n', ' ').trim();

void _writeTable(
  StringBuffer buffer,
  List<String> header,
  List<List<String>> rows, {
  Set<int> rightAligned = const {},
}) {
  final alignments = [
    for (var i = 0; i < header.length; i++)
      rightAligned.contains(i) ? ' ---: ' : ' --- ',
  ];
  buffer
    ..writeln('| ${header.join(' | ')} |')
    ..writeln('|${alignments.join('|')}|');
  for (final row in rows) {
    buffer.writeln('| ${row.join(' | ')} |');
  }
  buffer.writeln();
}

/// Formats [report] as GitHub-flavored Markdown.
String markdownReport(BenchmarkReport report) {
  final environment = report.environment;
  final configuration = report.configuration;
  final buffer = StringBuffer()
    ..writeln('# package:http client benchmarks')
    ..writeln()
    ..writeln('- **Machine:** ${_escape(environment.machine)}')
    ..writeln('- **Software:** ${_escape(environment.software)}')
    ..writeln(
      '- **Run:** ${report.startedAt.toIso8601String()} · '
      '${configuration.trials} trials (+${configuration.warmup} warmup) per '
      'scenario'
      '${configuration.quick ? ' · quick mode (reduced sizes)' : ''}'
      '${configuration.httpProfiling ? ' · HTTP profiling enabled' : ''}',
    )
    ..writeln();

  final unavailable = [
    for (final variant in report.variants)
      if (!variant.available) variant,
  ];
  if (unavailable.isNotEmpty) {
    buffer
      ..writeln('**Unavailable clients:**')
      ..writeln();
    for (final variant in unavailable) {
      buffer.writeln(
        '- ${variant.name}: ${_escape(variant.unavailableReason!)}',
      );
    }
    buffer.writeln();
  }

  final variants = report.availableVariants;
  final scores = scoreVariants(report);
  buffer
    ..writeln('## Summary')
    ..writeln()
    ..writeln(
      'Geometric mean of each client\'s performance relative to the best '
      'client in each scenario (1.00× means best in every scenario). '
      'Scenarios that measure memory use are excluded. '
      '${scoreBasis(report, scores)}',
    )
    ..writeln();
  _writeTable(
    buffer,
    ['Client', 'Protocol', 'Score', 'Wins', 'Failed'],
    [
      for (final score in scores)
        [
          score.variant.client,
          score.variant.protocol.label,
          score.score == null ? '–' : formatRatio(score.score!),
          '${score.wins}/${score.ratios.length}',
          '${score.failures}',
        ],
    ],
    rightAligned: {2, 3, 4},
  );

  buffer
    ..writeln('## Scoreboard')
    ..writeln()
    ..writeln(
      'Performance relative to the best client in each scenario. '
      '"!" marks runs where the server received requests using an '
      'unexpected protocol.',
    )
    ..writeln();
  _writeTable(
    buffer,
    ['Scenario', for (final variant in variants) variant.name],
    [
      for (final scenario in report.scenarios)
        _scoreboardRow(ScenarioSummary(report, scenario), variants),
    ],
    rightAligned: {for (var i = 1; i <= variants.length; i++) i},
  );

  for (final category in report.categories) {
    buffer
      ..writeln('## $category')
      ..writeln();
    for (final scenario in report.scenarios) {
      if (scenario.category != category) continue;
      _writeScenario(buffer, ScenarioSummary(report, scenario));
    }
  }
  return buffer.toString();
}

List<String> _scoreboardRow(
  ScenarioSummary summary,
  List<VariantInfo> variants,
) {
  String cell(VariantInfo variant) {
    final ranked = summary.ranked
        .where((r) => r.variant.id == variant.id)
        .firstOrNull;
    if (ranked == null) return '–';
    if (ranked.ratio == null) {
      return ranked.result.status == RunStatus.failed ? '✗' : '–';
    }
    final text =
        '${formatRatio(ranked.ratio!)}${ranked.protocolMismatch ? ' !' : ''}';
    return ranked.ratio == 1 ? '**$text**' : text;
  }

  final id = summary.scenario.id;
  return ['[`$id`](#$id)', for (final variant in variants) cell(variant)];
}

void _writeScenario(StringBuffer buffer, ScenarioSummary summary) {
  final scenario = summary.scenario;
  final metric = summary.metric;
  final sample = sampleLabels[summary.sampleName]!;
  buffer
    ..writeln('<a id="${scenario.id}"></a>')
    ..writeln('### ${scenario.title}')
    ..writeln()
    ..writeln('`${scenario.id}` · ${_escape(scenario.description)}')
    ..writeln();

  final notes = <String>[];
  final rows = <List<String>>[];
  for (final ranked in summary.ranked) {
    final result = ranked.result;
    final variant = ranked.variant;
    final protocol =
        '${variant.protocol.id}${ranked.protocolMismatch ? ' !' : ''}';
    if (ranked.protocolMismatch) {
      notes.add(
        '${variant.name}: the server received ${ranked.protocolDescription}.',
      );
    }
    if (!result.isOk) {
      rows.add([
        variant.client,
        protocol,
        result.status == RunStatus.failed ? '✗ failed' : 'skipped',
        for (var i = 0; i < 6; i++) '',
      ]);
      notes.add('${variant.name}: ${_escape(result.message ?? '')}');
      continue;
    }
    final samples = result.samples[summary.sampleName];
    final ttfb = result.samples['ttfb'];
    final value = formatMetric(metric, result.metric!.p50);
    rows.add([
      variant.client,
      protocol,
      '${ranked.ratio == 1 ? '**$value**' : value} '
          '±${formatPercent(result.metric!.relativeSpread)}',
      samples == null ? '–' : formatMicroseconds(samples.p50),
      samples == null ? '–' : formatMicroseconds(samples.p99),
      ttfb == null ? '–' : formatMicroseconds(ttfb.p50),
      '${result.connectionsUsed}',
      formatSizeDelta(result.peakRssDelta!),
      formatRatio(ranked.ratio!),
    ]);
    for (final note in result.notes.values) {
      notes.add('${variant.name}: ${_escape(note)}');
    }
  }
  _writeTable(
    buffer,
    [
      'Client',
      'Proto',
      '${metric.label} ${metric.higherIsBetter ? '▲' : '▼'}',
      '$sample p50',
      '$sample p99',
      'TTFB p50',
      'Conns',
      'Peak RSS',
      'Relative',
    ],
    rows,
    rightAligned: {2, 3, 4, 5, 6, 7, 8},
  );
  if (notes.isNotEmpty) {
    for (final note in notes) {
      buffer.writeln('- $note');
    }
    buffer.writeln();
  }
}
