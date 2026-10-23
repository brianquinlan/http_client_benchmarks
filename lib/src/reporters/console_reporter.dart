// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'dart:math' as math;

import '../clients.dart';
import '../environment.dart';
import '../format.dart';
import '../results.dart';
import '../runner.dart';
import '../scenario.dart';
import 'summary.dart';

final _ansiEscape = RegExp('\x1B\\[[0-9;]*m');

int _visibleLength(String text) =>
    text.replaceAll(_ansiEscape, '').runes.length;

/// Draws a horizontal bar representing [fraction] (between 0 and 1).
String bar(double fraction, {int width = 16}) {
  const partials = ['', '▏', '▎', '▍', '▌', '▋', '▊', '▉'];
  final eighths = (fraction.clamp(0, 1) * width * 8).round();
  return ('█' * (eighths ~/ 8) + partials[eighths % 8]).padRight(width);
}

/// Formats [rows] as a table with aligned columns.
String formatTable(
  List<List<String>> rows, {
  Set<int> rightAligned = const {},
  String indent = '  ',
}) {
  final widths = List.filled(rows.first.length, 0);
  for (final row in rows) {
    for (var i = 0; i < row.length; i++) {
      widths[i] = math.max(widths[i], _visibleLength(row[i]));
    }
  }
  final buffer = StringBuffer();
  for (final row in rows) {
    final cells = [
      for (var i = 0; i < row.length; i++)
        rightAligned.contains(i)
            ? '${' ' * (widths[i] - _visibleLength(row[i]))}${row[i]}'
            : '${row[i]}${' ' * (widths[i] - _visibleLength(row[i]))}',
    ];
    buffer.writeln('$indent${cells.join('  ')}'.trimRight());
  }
  return buffer.toString();
}

/// Writes benchmark progress and results to a terminal.
class ConsoleReporter implements RunnerListener {
  ConsoleReporter({IOSink? sink, bool? color, bool? interactive})
    : _sink = sink ?? stdout,
      _color = color ?? (stdout.hasTerminal && stdout.supportsAnsiEscapes),
      _interactive = interactive ?? stdout.hasTerminal;

  final IOSink _sink;
  final bool _color;
  final bool _interactive;

  final _variants = <VariantInfo>[];
  late Environment _environment;
  late RunConfiguration _configuration;
  String? _caCertificatePath;
  var _scenarioCount = 0;
  var _scenarioIndex = 0;
  var _progressVisible = false;

  String _style(String text, String code) =>
      _color && text.isNotEmpty ? '\x1B[${code}m$text\x1B[0m' : text;
  String _bold(String text) => _style(text, '1');
  String _dim(String text) => _style(text, '2');
  String _red(String text) => _style(text, '31');
  String _green(String text) => _style(text, '32');
  String _yellow(String text) => _style(text, '33');
  String _cyan(String text) => _style(text, '36');

  String _rule(String title) {
    const width = 100;
    return _bold('━━ $title ${'━' * math.max(3, width - title.length - 4)}');
  }

  void _clearProgress() {
    if (_progressVisible) {
      _sink.write('\r\x1B[2K');
      _progressVisible = false;
    }
  }

  /// Writes a description of the benchmark run.
  ///
  /// [caCertificatePath] is the location of the benchmark CA, which is
  /// mentioned if a client cannot connect because it does not trust the CA.
  void printHeader({
    required Environment environment,
    required RunConfiguration configuration,
    required int scenarioCount,
    String? caCertificatePath,
  }) {
    _environment = environment;
    _configuration = configuration;
    _scenarioCount = scenarioCount;
    _caCertificatePath = caCertificatePath;
    _sink
      ..writeln(_bold('package:http client benchmarks'))
      ..writeln('  ${environment.machine}')
      ..writeln('  ${environment.software}')
      ..writeln(
        '  $scenarioCount scenarios · ${configuration.trials} trials '
        '(+${configuration.warmup} warmup) per scenario'
        '${configuration.quick ? ' · quick mode (reduced sizes)' : ''}'
        '${configuration.httpProfiling ? ' · HTTP profiling enabled' : ''}',
      )
      ..writeln()
      ..writeln(_bold('Clients'));
  }

  /// Explains how to trust the benchmark CA, which `CupertinoClient` needs in
  /// order to use TLS.
  void printTrustHint(String caCertificatePath) {
    _sink
      ..writeln()
      ..writeln(
        _yellow(
          '  CupertinoClient can only use TLS (and therefore HTTP/2 and '
          'HTTP/3) when the benchmark CA is trusted by macOS.',
        ),
      )
      ..writeln(
        '  The CA can only issue TLS server certificates for localhost. To '
        'trust it for TLS, run:',
      )
      ..writeln(
        '    security add-trusted-cert -r trustRoot -p ssl '
        '-k ~/Library/Keychains/login.keychain-db $caCertificatePath',
      )
      ..writeln('  To remove it later, run:')
      ..writeln('    security remove-trusted-cert $caCertificatePath');
  }

  @override
  void onVariantChecked(VariantInfo variant) {
    _variants.add(variant);
    final name = variant.name.padRight(22);
    if (variant.available) {
      _sink.writeln('  ${_green('✓')} $name ${_dim(variant.protocol.label)}');
    } else {
      _sink.writeln(
        '  ${_red('✗')} $name ${_dim(variant.protocol.label)} '
        '${_red('unavailable:')} ${variant.unavailableReason}',
      );
    }
  }

  @override
  void onVariantsChecked(List<VariantInfo> variants) {
    final caCertificatePath = _caCertificatePath;
    final cupertinoTlsUnavailable = variants.any(
      (v) => v.client == 'CupertinoClient' && v.protocol.secure && !v.available,
    );
    if (cupertinoTlsUnavailable && caCertificatePath != null) {
      printTrustHint(caCertificatePath);
    }
  }

  @override
  void onScenarioStarted(Scenario scenario) {
    _scenarioIndex++;
  }

  @override
  void onRunStarted(Scenario scenario, ClientVariant variant) {
    if (!_interactive) return;
    _clearProgress();
    _sink.write(
      _dim(
        '  [$_scenarioIndex/$_scenarioCount] ${scenario.id} · '
        '${variant.name} …',
      ),
    );
    _progressVisible = true;
  }

  @override
  void onScenarioFinished(Scenario scenario, List<RunResult> results) {
    _clearProgress();
    final info = ScenarioInfo(
      id: scenario.id,
      title: scenario.title,
      category: scenario.category,
      description: scenario.description,
      metric: scenario.metric,
    );
    final partial = BenchmarkReport(
      startedAt: DateTime.now(),
      finishedAt: DateTime.now(),
      environment: _environment,
      configuration: _configuration,
      variants: _variants,
      scenarios: [info],
      results: results,
    );
    printScenario(ScenarioSummary(partial, info));
  }

  /// Writes a table of the results of a scenario.
  void printScenario(ScenarioSummary summary) {
    final scenario = summary.scenario;
    final metric = summary.metric;
    final sample = sampleLabels[summary.sampleName]!;
    _sink
      ..writeln()
      ..writeln(_rule('${scenario.category} · ${scenario.id}'))
      ..writeln('  ${scenario.title}');
    if (summary.ranked.isEmpty) {
      _sink.writeln(_dim('  No results.'));
      return;
    }

    final rows = <List<String>>[
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
      ].map(_bold).toList(),
    ];
    final footnotes = <String>[];
    for (final ranked in summary.ranked) {
      final result = ranked.result;
      final variant = ranked.variant;
      var protocol = variant.protocol.id;
      if (ranked.protocolMismatch) {
        protocol = _yellow('$protocol!');
        footnotes.add(
          _yellow(
            '! ${variant.name}: the server received '
            '${ranked.protocolDescription}',
          ),
        );
      }
      if (!result.isOk) {
        final failed = result.status == RunStatus.failed;
        rows.add([
          variant.client,
          protocol,
          failed ? _red('failed') : _dim('skipped'),
          for (var i = 0; i < 6; i++) '',
        ]);
        footnotes.add(
          '${failed ? _red('✗') : _dim('–')} ${variant.name}: '
          '${result.message}',
        );
        continue;
      }
      final best = ranked.ratio == 1;
      final samples = result.samples[summary.sampleName];
      final ttfb = result.samples['ttfb'];
      final value = formatMetric(metric, result.metric!.p50);
      rows.add([
        best ? _green(variant.client) : variant.client,
        protocol,
        '${best ? _green(value) : value} '
            '${_dim('±${formatPercent(result.metric!.relativeSpread)}')}',
        samples == null ? '–' : formatMicroseconds(samples.p50),
        samples == null ? '–' : formatMicroseconds(samples.p99),
        ttfb == null ? '–' : formatMicroseconds(ttfb.p50),
        '${result.connectionsUsed}',
        formatSizeDelta(result.peakRssDelta!),
        '${_cyan(bar(ranked.ratio!))} ${formatRatio(ranked.ratio!)}',
      ]);
      for (final note in result.notes.values) {
        footnotes.add(_dim('· ${variant.name}: $note'));
      }
    }
    _sink.write(formatTable(rows, rightAligned: {2, 3, 4, 5, 6, 7}));
    for (final footnote in footnotes) {
      _sink.writeln('  $footnote');
    }
  }

  /// Writes the overall ranking of the client variants.
  void printSummary(BenchmarkReport report, {List<String> outputs = const []}) {
    _clearProgress();
    final scores = scoreVariants(report);
    final elapsed = report.finishedAt.difference(report.startedAt);
    _sink
      ..writeln()
      ..writeln(_rule('Summary'))
      ..writeln(
        '  Geometric mean of each client\'s performance relative to the best '
        'client in each scenario',
      )
      ..writeln(
        _dim(
          '  (1.00× means best in every scenario; memory scenarios are '
          'excluded).',
        ),
      )
      ..writeln(_dim('  ${scoreBasis(report, scores)}'));
    final rows = <List<String>>[
      ['Client', 'Proto', 'Score', 'Wins', 'Failed', ''].map(_bold).toList(),
      for (final score in scores)
        [
          score.variant.client,
          score.variant.protocol.id,
          score.score == null ? '–' : formatRatio(score.score!),
          '${score.wins}/${score.ratios.length}',
          score.failures == 0 ? '0' : _red('${score.failures}'),
          score.score == null ? '' : _cyan(bar(score.score!, width: 24)),
        ],
    ];
    _sink.write(formatTable(rows, rightAligned: {2, 3, 4}));
    _sink.writeln(
      _dim(
        '\n  Finished ${report.results.length} runs in '
        '${elapsed.inMinutes}m ${elapsed.inSeconds % 60}s.',
      ),
    );
    if (outputs.isNotEmpty) {
      _sink.writeln('\n${_bold('Reports')}');
      for (final output in outputs) {
        _sink.writeln('  $output');
      }
    }
  }
}
