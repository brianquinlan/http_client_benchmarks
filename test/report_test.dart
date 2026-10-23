// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http_client_benchmarks/http_client_benchmarks.dart';
import 'package:http_client_benchmarks/src/reporters/summary.dart';
import 'package:test/test.dart';

const _mib = 1024 * 1024;

final _variants = [
  VariantInfo(
    id: 'ioclient-h1c',
    client: 'IOClient',
    protocol: HttpProtocol.http1Cleartext,
  ),
  VariantInfo(
    id: 'http2client-h2',
    client: 'Http2Client',
    protocol: HttpProtocol.http2,
  ),
  VariantInfo(
    id: 'cupertinoclient-h3',
    client: 'CupertinoClient',
    protocol: HttpProtocol.http3,
  ),
  VariantInfo(
    id: 'cupertinoclient-h2',
    client: 'CupertinoClient',
    protocol: HttpProtocol.http2,
    unavailableReason: '<b>The certificate is invalid</b>',
  ),
];

ScenarioInfo _scenario(String id, Metric metric, {String category = 'Tests'}) =>
    ScenarioInfo(
      id: id,
      title: 'Title of $id',
      category: category,
      description: 'Description of `$id`.',
      metric: metric,
    );

RunResult _ok(
  String scenario,
  String variant,
  List<double> values, {
  Map<String, int>? protocols,
  Map<String, String> notes = const {},
}) {
  final protocol = _variants
      .firstWhere((v) => v.id == variant)
      .protocol
      .serverProtocol;
  final used = protocols ?? {protocol: 10};
  return RunResult(
    scenarioId: scenario,
    variantId: variant,
    status: RunStatus.ok,
    trials: [
      for (final value in values)
        TrialResult(
          durationMicros: 1000000,
          operations: 10,
          bytesSent: 0,
          bytesReceived: 10 * _mib,
          metricValue: value,
          connectionsUsed: 1,
          connectionsOpened: 0,
          peakRssDelta: 2048,
          protocols: used,
          samples: {
            'latency': Distribution.of([value, value * 2]),
            'ttfb': Distribution.of([value / 2]),
          },
        ),
    ],
    samples: {
      'latency': Distribution.of([for (final value in values) value]),
      'ttfb': Distribution.of([for (final value in values) value / 2]),
    },
    protocols: used,
    notes: notes,
  );
}

BenchmarkReport _report({
  List<ScenarioInfo>? scenarios,
  List<RunResult>? results,
  bool quick = false,
  String dartVersion = '3.13.1',
}) => BenchmarkReport(
  startedAt: DateTime(2026, 10, 22, 14),
  finishedAt: DateTime(2026, 10, 22, 14, 5),
  environment: Environment(
    operatingSystem: 'macos',
    operatingSystemVersion: '26.0',
    dartVersion: dartVersion,
    compilationMode: 'JIT',
    cpu: 'Test CPU',
    processors: 8,
    memoryBytes: 16 << 30,
    goVersion: 'go1.26.5',
    quicGoVersion: 'v0.64.1',
    gitRevision: 'abc1234',
  ),
  configuration: RunConfiguration(
    trials: 3,
    warmup: 1,
    quick: quick,
    httpProfiling: false,
  ),
  variants: _variants,
  scenarios:
      scenarios ??
      [
        _scenario('get-sequential', Metric.latency),
        _scenario('get-concurrent-16', Metric.requestsPerSecond),
        _scenario('download-large', Metric.throughput, category: 'Downloads'),
        _scenario(
          'download-slow-consumer',
          Metric.peakMemory,
          category: 'Downloads',
        ),
      ],
  results:
      results ??
      [
        _ok('get-sequential', 'ioclient-h1c', [100, 110, 105]),
        _ok('get-sequential', 'http2client-h2', [200, 210, 190]),
        RunResult.failed(
          'get-sequential',
          'cupertinoclient-h3',
          'A trial took longer than 120s',
        ),
        _ok('get-concurrent-16', 'ioclient-h1c', [5000, 5100, 5050]),
        _ok('get-concurrent-16', 'http2client-h2', [8000, 8100, 8050]),
        _ok('get-concurrent-16', 'cupertinoclient-h3', [4000, 4100, 4050]),
        _ok('download-large', 'ioclient-h1c', [1000, 1100, 1050]),
        _ok(
          'download-large',
          'http2client-h2',
          [500, 520, 510],
          notes: {'decompression': 'Decompressed by the benchmark.'},
        ),
        _ok(
          'download-large',
          'cupertinoclient-h3',
          [800, 820, 810],
          protocols: {'HTTP/2.0': 5, 'HTTP/3.0': 5},
        ),
        _ok('download-slow-consumer', 'ioclient-h1c', [16384, 16384, 16384]),
        _ok('download-slow-consumer', 'http2client-h2', [64.0 * _mib]),
        RunResult.skipped(
          'download-slow-consumer',
          'cupertinoclient-h3',
          'Not applicable',
        ),
      ],
);

Future<String> _capture(void Function(ConsoleReporter reporter) write) async {
  final controller = StreamController<List<int>>();
  final output = controller.stream.transform(utf8.decoder).join();
  final sink = IOSink(controller.sink);
  write(ConsoleReporter(sink: sink, color: false, interactive: false));
  await sink.close();
  return output;
}

void main() {
  test('reports round trip through JSON', () {
    final report = _report();
    final json = jsonEncode(report.toJson());
    final copy = BenchmarkReport.fromJson(
      jsonDecode(json) as Map<String, Object?>,
    );
    expect(jsonEncode(copy.toJson()), json);
  });

  test('rejects unknown schema versions', () {
    final json = _report().toJson()..['schemaVersion'] = 999;
    expect(() => BenchmarkReport.fromJson(json), throwsFormatException);
  });

  group('ScenarioSummary', () {
    test('ranks results from best to worst', () {
      final report = _report();
      final ranked = ScenarioSummary(
        report,
        report.scenario('get-sequential'),
      ).ranked;
      expect(ranked.map((r) => r.variant.id), [
        'ioclient-h1c',
        'http2client-h2',
        'cupertinoclient-h3',
      ]);
      expect(ranked[0].ratio, 1);
      expect(ranked[1].ratio, closeTo(105 / 200, 1e-9));
      expect(ranked[2].ratio, isNull);
    });

    test('detects unexpected protocols', () {
      final report = _report();
      final ranked = ScenarioSummary(
        report,
        report.scenario('download-large'),
      ).ranked;
      final cupertino = ranked.firstWhere(
        (r) => r.variant.id == 'cupertinoclient-h3',
      );
      expect(cupertino.protocolMismatch, isTrue);
      expect(cupertino.protocolDescription, 'HTTP/2.0 50%, HTTP/3.0 50%');
      expect(ranked.first.protocolMismatch, isFalse);
    });
  });

  test('scoreVariants only scores scenarios that every client completed', () {
    final report = _report();
    final scores = scoreVariants(report);
    // get-sequential has a failure, download-large has a protocol mismatch
    // and download-slow-consumer measures memory.
    for (final score in scores) {
      expect(score.ratios.keys, ['get-concurrent-16']);
    }
    expect(scores.map((s) => s.variant.id), [
      'http2client-h2',
      'ioclient-h1c',
      'cupertinoclient-h3',
    ]);
    expect(scores.first.score, 1);
    expect(scores.first.wins, 1);
    expect(scores[1].score, closeTo(5050 / 8050, 1e-9));
    expect(scores.last.failures, 1);
    expect(
      scoreBasis(report, scores),
      'Scores cover the 1 of 3 speed scenarios that every client completed '
      'using its expected protocol.',
    );
  });

  test('markdownReport', () {
    final markdown = markdownReport(_report());
    expect(markdown, contains('# package:http client benchmarks'));
    expect(markdown, contains('## Summary'));
    expect(markdown, contains('## Scoreboard'));
    expect(markdown, contains('## Downloads'));
    expect(markdown, contains('| IOClient | h1c | **105 µs** ±'));
    expect(markdown, contains('✗ failed'));
    expect(
      markdown,
      contains('the server received HTTP/2.0 50%, HTTP/3.0 50%'),
    );
    expect(markdown, contains('Decompressed by the benchmark.'));
    expect(markdown, contains('CupertinoClient h2: <b>The certificate'));
  });

  group('htmlReport', () {
    test('is a self-contained page', () {
      final html = htmlReport(_report());
      expect(html, startsWith('<!DOCTYPE html>'));
      expect(html.trimRight(), endsWith('</html>'));
      expect(html, isNot(contains('<script src')));
      expect(html, isNot(contains('<link')));
      expect(html, contains('id="benchmark-data"'));
      expect(html, contains('<svg'));
      expect(html, contains('data-value="105.0"'));
      expect(html, contains('<code>get-sequential</code>'));
    });

    test('escapes untrusted text', () {
      final html = htmlReport(_report());
      final markup = html.substring(0, html.indexOf('id="benchmark-data"'));
      expect(markup, contains('&lt;b&gt;The certificate is invalid'));
      expect(markup, isNot(contains('<b>The certificate')));
      // The embedded JSON cannot close its <script> element early.
      final json = html.substring(html.indexOf('id="benchmark-data"'));
      expect(json, contains(r'\u003cb>The certificate is invalid\u003c/b>'));
      expect(json, isNot(contains('<b>')));
    });

    test('escapes IDs', () {
      const id = '"><script>alert(1)</script>';
      final html = htmlReport(
        _report(
          scenarios: [_scenario(id, Metric.latency)],
          results: [
            _ok(id, 'ioclient-h1c', [100, 100, 100]),
          ],
        ),
      );
      final markup = html.substring(0, html.indexOf('id="benchmark-data"'));
      expect(markup, isNot(contains('<script>alert')));
      expect(markup, contains('id="&quot;&gt;&lt;script&gt;alert(1)'));
    });

    test('draws the scaling chart when the GET scenarios are present', () {
      final report = _report(
        scenarios: [
          _scenario('get-sequential', Metric.latency),
          _scenario('get-concurrent-16', Metric.requestsPerSecond),
          _scenario('get-concurrent-128', Metric.requestsPerSecond),
        ],
        results: [
          for (final id in [
            'get-sequential',
            'get-concurrent-16',
            'get-concurrent-128',
          ])
            _ok(id, 'ioclient-h1c', [100, 100, 100]),
        ],
      );
      expect(htmlReport(report), contains('id="scaling"'));
      expect(htmlReport(_report()), isNot(contains('id="scaling"')));
    });
  });

  test('ConsoleReporter prints scenario tables and summaries', () async {
    final report = _report();
    final output = await _capture((reporter) {
      for (final scenario in report.scenarios) {
        reporter.printScenario(ScenarioSummary(report, scenario));
      }
      reporter.printSummary(report, outputs: ['results.json']);
    });
    expect(output, contains('Tests · get-sequential'));
    expect(output, contains('Median latency ▼'));
    expect(output, contains('1.00×'));
    expect(output, contains('failed'));
    expect(output, contains('✗ CupertinoClient h3: A trial took longer'));
    expect(output, contains('h3!'));
    expect(output, contains('Summary'));
    expect(output, contains('results.json'));
    expect(output, isNot(contains('\x1B[')));
  });

  group('compareReports', () {
    BenchmarkReport single(
      List<double> values, {
      bool quick = false,
      String title = 'Title of get-sequential',
      String dartVersion = '3.13.1',
      Metric metric = Metric.latency,
    }) => _report(
      scenarios: [
        ScenarioInfo(
          id: 'get-sequential',
          title: title,
          category: 'Tests',
          description: 'Description.',
          metric: metric,
        ),
      ],
      results: [_ok('get-sequential', 'ioclient-h1c', values)],
      quick: quick,
      dartVersion: dartVersion,
    );

    test('reports significant changes', () {
      final comparisons = compareReports(
        single([100, 101, 102, 103, 104, 105, 106]),
        single([80, 81, 82, 83, 84, 85, 86]),
      );
      expect(comparisons, hasLength(1));
      final comparison = comparisons.single;
      expect(comparison.change, closeTo(-0.2, 0.01));
      expect(comparison.improved, isTrue);
      expect(comparison.isSignificant(0.05), isTrue);
      expect(comparison.verdict(), Verdict.improved);
      final table = formatComparisons(comparisons);
      expect(table, contains('-19.4%'));
      expect(table, contains('1 improved, 0 regressed, 0 unchanged.'));
      expect(formatComparisonsMarkdown(comparisons), contains('🟢'));
    });

    test('ignores noise', () {
      final comparison = compareReports(
        single([100, 104, 101, 103, 102]),
        single([102, 100, 103, 101, 104]),
      ).single;
      expect(comparison.isSignificant(0.05), isFalse);
      expect(comparison.verdict(), Verdict.unchanged);
      expect(formatComparisons([comparison]), contains('~'));
    });

    test('ignores changes smaller than the threshold', () {
      final comparison = compareReports(
        single([100, 100.1, 100.2, 100.3, 100.4, 100.5, 100.6]),
        single([97, 97.1, 97.2, 97.3, 97.4, 97.5, 97.6]),
      ).single;
      expect(comparison.isSignificant(0.05), isTrue);
      expect(comparison.verdict(), Verdict.improved);
      expect(comparison.verdict(threshold: 0.05), Verdict.unchanged);
      expect(
        formatComparisons([comparison], threshold: 0.05),
        contains('or are smaller than 5.0%'),
      );
    });

    test('treats values below the noise floor as equal', () {
      final comparison = compareReports(
        single([1000, 1001, 1002], metric: Metric.peakMemory),
        single([50000, 50001, 50002], metric: Metric.peakMemory),
      ).single;
      expect(comparison.change, 0);
    });

    test('reports when there are too few trials', () {
      final comparison = compareReports(
        single([100, 101, 102]),
        single([50, 51, 52]),
      ).single;
      expect(comparison.canBeSignificant(0.05), isFalse);
      expect(comparison.verdict(), Verdict.inconclusive);
      final table = formatComparisons([comparison]);
      expect(table, contains('?'));
      expect(table, contains('use at least 4 trials per run'));
    });

    test('can control the false discovery rate', () {
      final comparison = compareReports(
        single([100, 101, 102, 103, 104, 105, 106]),
        single([80, 81, 82, 83, 84, 85, 86]),
        controlFalseDiscoveryRate: true,
      ).single;
      // With a single comparison, the adjustment has no effect.
      expect(comparison.adjustedPValue, comparison.pValue);
      expect(formatComparisons([comparison]), contains('Benjamini-Hochberg'));
    });

    test('skips scenarios that changed and warns about them', () {
      final baseline = single([100, 101, 102, 103]);
      final candidate = single([80, 81, 82, 83], title: 'A different title');
      expect(compareReports(baseline, candidate), isEmpty);
      expect(compatibilityWarnings(baseline, candidate), [
        contains('get-sequential'),
      ]);
    });

    test('warns about different software', () {
      final warnings = compatibilityWarnings(
        single([100]),
        single([100], dartVersion: '3.14.0'),
      );
      expect(warnings, [contains('Dart 3.14.0')]);
      expect(compatibilityWarnings(single([100]), single([100])), isEmpty);
    });

    test('rejects reports with different payload sizes', () {
      expect(
        () => compareReports(single([1]), single([1], quick: true)),
        throwsFormatException,
      );
    });
  });

  group('selection', () {
    final scenarios = createScenarios(quick: true);

    test('selectScenarios', () {
      expect(
        selectScenarios(scenarios, patterns: ['upload']).map((s) => s.id),
        everyElement(contains('upload')),
      );
      expect(
        selectScenarios(scenarios, patterns: ['get-*-16']).map((s) => s.id),
        ['get-concurrent-16'],
      );
      expect(
        selectScenarios(
          scenarios,
          categories: ['connections'],
        ).map((s) => s.id),
        ['cold-client'],
      );
      expect(selectScenarios(scenarios), hasLength(scenarios.length));
    });

    test('selectVariants', () {
      final variants = createClientVariants();
      expect(selectVariants(variants, clients: ['ioclient']).map((v) => v.id), [
        'ioclient-h1c',
        'ioclient-h1',
      ]);
      expect(
        selectVariants(variants, protocols: ['h2']).map((v) => v.client),
        everyElement(isIn(['Http2Client', 'CupertinoClient'])),
      );
    });

    test('scenario IDs are unique', () {
      final ids = scenarios.map((s) => s.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
    });
  });

  test('writeReports writes every format', () async {
    final directory = await Directory.systemTemp.createTemp('benchmarks');
    addTearDown(() => directory.delete(recursive: true));
    final outputs = await writeReports(
      _report(),
      outputDirectory: directory.path,
    );
    expect(outputs.map((path) => path.split(Platform.pathSeparator).last), [
      'results.json',
      'report.html',
      'report.md',
    ]);
    for (final path in outputs) {
      expect(File(path).lengthSync(), greaterThan(0));
    }
  });
}
