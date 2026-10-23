// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'clients.dart';
import 'compare.dart';
import 'environment.dart';
import 'protocol.dart';
import 'reporters/console_reporter.dart';
import 'reporters/html_reporter.dart';
import 'reporters/markdown_reporter.dart';
import 'reporters/summary.dart';
import 'results.dart';
import 'runner.dart';
import 'scenario.dart';
import 'scenarios.dart';
import 'server.dart';

/// Runs the benchmark command-line interface and returns the exit code.
Future<int> runCli(List<String> arguments) async {
  final runner =
      CommandRunner<int>(
          'benchmark',
          'Benchmarks package:http Client implementations over HTTP/1.1, '
              'HTTP/2 and HTTP/3.',
        )
        ..addCommand(RunCommand())
        ..addCommand(CompareCommand())
        ..addCommand(ReportCommand())
        ..addCommand(ListCommand());
  try {
    return await runner.run(arguments) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    return 64;
  } on BenchmarkServerException catch (e) {
    stderr.writeln('Error: ${e.message}');
    return 1;
  }
}

/// Returns the scenarios whose ID matches one of [patterns] (in which "*" is
/// a wildcard; patterns without "*" match any ID containing them) and whose
/// category is one of [categories].
///
/// Empty lists match every scenario.
List<Scenario> selectScenarios(
  List<Scenario> scenarios, {
  List<String> patterns = const [],
  List<String> categories = const [],
}) {
  bool matches(String id, String pattern) => pattern.contains('*')
      ? RegExp(
          '^${pattern.split('*').map(RegExp.escape).join('.*')}\$',
        ).hasMatch(id)
      : id.contains(pattern);

  return [
    for (final scenario in scenarios)
      if ((patterns.isEmpty ||
              patterns.any((pattern) => matches(scenario.id, pattern))) &&
          (categories.isEmpty ||
              categories.any(
                (c) => c.toLowerCase() == scenario.category.toLowerCase(),
              )))
        scenario,
  ];
}

/// Returns the variants of the given [clients] (lowercase names) that use
/// one of the given [protocols] (protocol IDs).
///
/// Empty lists match every variant.
List<ClientVariant> selectVariants(
  List<ClientVariant> variants, {
  List<String> clients = const [],
  List<String> protocols = const [],
}) => [
  for (final variant in variants)
    if ((clients.isEmpty || clients.contains(variant.client.toLowerCase())) &&
        (protocols.isEmpty || protocols.contains(variant.protocol.id)))
      variant,
];

/// Writes [report] to [outputDirectory] and returns the paths of the files
/// written.
///
/// If [timestamped] is true then the files are written to a new
/// subdirectory named after the time at which the benchmarks started.
Future<List<String>> writeReports(
  BenchmarkReport report, {
  required String outputDirectory,
  bool timestamped = true,
  bool json = true,
  bool html = true,
  bool markdown = true,
}) async {
  final timestamp = report.startedAt
      .toIso8601String()
      .substring(0, 19)
      .replaceAll(':', '-')
      .replaceAll('T', '_');
  final directory = await Directory(
    timestamped ? p.join(outputDirectory, timestamp) : outputDirectory,
  ).create(recursive: true);
  final outputs = <String>[];
  Future<void> write(String name, String contents) async {
    final file = File(p.join(directory.path, name));
    await file.writeAsString(contents);
    outputs.add(file.path);
  }

  if (json) {
    await write(
      'results.json',
      const JsonEncoder.withIndent(' ').convert(report.toJson()),
    );
  }
  if (html) await write('report.html', htmlReport(report));
  if (markdown) await write('report.md', markdownReport(report));
  return outputs;
}

Future<BenchmarkReport> _loadReport(String path) async =>
    BenchmarkReport.fromJson(
      jsonDecode(await File(path).readAsString()) as Map<String, Object?>,
    );

/// Runs the benchmarks.
class RunCommand extends Command<int> {
  RunCommand() {
    argParser
      ..addMultiOption(
        'client',
        abbr: 'c',
        help: 'Only benchmark these clients.',
        allowed: [for (final name in clientNames) name.toLowerCase()],
      )
      ..addMultiOption(
        'protocol',
        abbr: 'p',
        help: 'Only use these protocols.',
        allowed: [for (final protocol in HttpProtocol.values) protocol.id],
        allowedHelp: {
          for (final protocol in HttpProtocol.values)
            protocol.id: protocol.label,
        },
      )
      ..addMultiOption(
        'scenario',
        abbr: 's',
        help:
            'Only run scenarios whose ID contains one of these patterns. '
            '"*" is a wildcard.',
        valueHelp: 'pattern',
      )
      ..addMultiOption(
        'category',
        help: 'Only run scenarios in these categories.',
        allowed: [
          Categories.concurrency,
          Categories.downloads,
          Categories.uploads,
          Categories.connections,
          Categories.payloads,
        ].map((c) => c.toLowerCase()),
      )
      ..addOption(
        'trials',
        abbr: 't',
        help:
            'The number of measured trials per scenario (default 7, or 3 '
            'with --quick).',
        valueHelp: 'count',
      )
      ..addOption(
        'warmup',
        help:
            'The number of warmup trials per scenario (default 2, or 1 '
            'with --quick).',
        valueHelp: 'count',
      )
      ..addFlag(
        'quick',
        abbr: 'q',
        negatable: false,
        help: 'Use fewer trials and smaller payloads, e.g. as a smoke test.',
      )
      ..addFlag(
        'http-profiling',
        negatable: false,
        help:
            'Enable the HTTP profiling used by the DevTools network view, to '
            'measure its overhead. Profiling records request and response '
            'bodies, so consider combining this with --quick.',
      )
      ..addOption(
        'output-dir',
        abbr: 'o',
        defaultsTo: 'benchmark_results',
        help: 'The directory in which to write reports.',
      )
      ..addFlag('json', defaultsTo: true, help: 'Write results.json.')
      ..addFlag('html', defaultsTo: true, help: 'Write report.html.')
      ..addFlag('markdown', defaultsTo: true, help: 'Write report.md.')
      ..addOption(
        'trial-timeout',
        defaultsTo: '120',
        help: 'The number of seconds after which a trial is abandoned.',
        valueHelp: 'seconds',
      )
      ..addOption(
        'cert-dir',
        help:
            'The directory containing the benchmark CA (default: '
            '.dart_tool/http_client_benchmarks/certs in this package).',
        valueHelp: 'path',
      )
      ..addFlag(
        'color',
        help: 'Use colors in the output (default: auto-detect).',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Show the output of the benchmark server.',
      );
  }

  @override
  String get name => 'run';

  @override
  String get description => 'Runs the benchmarks.';

  int? _intOption(String name, {int min = 0}) {
    final value = argResults!.option(name);
    if (value == null) return null;
    final parsed = int.tryParse(value);
    if (parsed == null || parsed < min) {
      usageException('--$name must be an integer of at least $min.');
    }
    return parsed;
  }

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.isNotEmpty) {
      usageException('Unexpected arguments: ${args.rest.join(' ')}');
    }
    final quick = args.flag('quick');
    final verbose = args.flag('verbose');
    final configuration = RunConfiguration(
      trials: _intOption('trials', min: 1) ?? (quick ? 3 : 7),
      warmup: _intOption('warmup') ?? (quick ? 1 : 2),
      quick: quick,
      httpProfiling: args.flag('http-profiling'),
    );
    final trialTimeout = Duration(
      seconds: _intOption('trial-timeout', min: 1)!,
    );
    final scenarios = selectScenarios(
      createScenarios(quick: quick),
      patterns: args.multiOption('scenario'),
      categories: args.multiOption('category'),
    );
    if (scenarios.isEmpty) {
      usageException('No scenarios match the given filters.');
    }

    // `HttpClientRequestProfile.profilingEnabled` is backed by this setting.
    HttpClient.enableTimelineLogging = configuration.httpProfiling;

    final console = ConsoleReporter(
      color: args.wasParsed('color') ? args.flag('color') : null,
    );
    stdout.writeln('Building and starting the benchmark server…');
    final server = await BenchmarkServer.start(
      certificateDirectory: args.option('cert-dir'),
      verbose: verbose,
    );
    try {
      final variants = selectVariants(
        createClientVariants(caCertificate: server.caCertificate),
        clients: args.multiOption('client'),
        protocols: args.multiOption('protocol'),
      );
      if (variants.isEmpty) {
        usageException('No clients match the given filters.');
      }
      final environment = await Environment.capture(
        goVersion: server.goVersion,
        quicGoVersion: server.quicGoVersion,
        workingDirectory: await BenchmarkServer.packageDirectory(),
      );
      console.printHeader(
        environment: environment,
        configuration: configuration,
        scenarioCount: scenarios.length,
        caCertificatePath: server.caCertificatePath,
      );
      final report = await BenchmarkRunner(
        server: server,
        environment: environment,
        variants: variants,
        scenarios: scenarios,
        configuration: configuration,
        trialTimeout: trialTimeout,
        listener: console,
        verbose: verbose,
      ).run();
      final outputs = await writeReports(
        report,
        outputDirectory: args.option('output-dir')!,
        json: args.flag('json'),
        html: args.flag('html'),
        markdown: args.flag('markdown'),
      );
      console.printSummary(report, outputs: outputs);
      return report.results.any((r) => r.status == RunStatus.failed) ? 1 : 0;
    } finally {
      await server.close();
    }
  }
}

/// Compares two benchmark results files.
class CompareCommand extends Command<int> {
  CompareCommand() {
    argParser
      ..addOption(
        'alpha',
        defaultsTo: '0.05',
        help: 'The significance level for reporting a change.',
      )
      ..addOption(
        'threshold',
        defaultsTo: '5',
        help:
            'Report changes smaller than this percentage as unchanged, even '
            'if they are statistically significant.',
        valueHelp: 'percent',
      )
      ..addFlag(
        'fdr',
        negatable: false,
        help:
            'Adjust p-values for the number of comparisons '
            '(Benjamini-Hochberg), reducing false positives.',
      )
      ..addOption(
        'markdown',
        help: 'Also write the comparison as Markdown to this file.',
        valueHelp: 'path',
      );
  }

  @override
  String get name => 'compare';

  @override
  String get description =>
      'Compares two results.json files, reporting statistically significant '
      'changes.';

  @override
  String get invocation =>
      '${runner!.executableName} compare <baseline.json> <candidate.json>';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.length != 2) {
      usageException('Expected two results files.');
    }
    final alpha = double.tryParse(args.option('alpha')!);
    if (alpha == null || alpha <= 0 || alpha >= 1) {
      usageException('--alpha must be a number between 0 and 1.');
    }
    final thresholdPercent = double.tryParse(args.option('threshold')!);
    if (thresholdPercent == null || thresholdPercent < 0) {
      usageException('--threshold must be a non-negative percentage.');
    }
    final threshold = thresholdPercent / 100;
    final List<Comparison> comparisons;
    final List<String> warnings;
    try {
      final baseline = await _loadReport(args.rest[0]);
      final candidate = await _loadReport(args.rest[1]);
      comparisons = compareReports(
        baseline,
        candidate,
        controlFalseDiscoveryRate: args.flag('fdr'),
      );
      warnings = compatibilityWarnings(baseline, candidate);
    } on FormatException catch (e) {
      stderr.writeln('Error: ${e.message}');
      return 1;
    } on FileSystemException catch (e) {
      stderr.writeln('Error: ${e.message}: ${e.path}');
      return 1;
    }
    if (comparisons.isEmpty) {
      warnings.forEach(stderr.writeln);
      stderr.writeln('The results files have no successful runs in common.');
      return 1;
    }
    stdout.write(
      formatComparisons(
        comparisons,
        alpha: alpha,
        threshold: threshold,
        color: stdout.hasTerminal && stdout.supportsAnsiEscapes,
        warnings: warnings,
      ),
    );
    if (args.option('markdown') case final path?) {
      await File(path).writeAsString(
        formatComparisonsMarkdown(
          comparisons,
          alpha: alpha,
          threshold: threshold,
          warnings: warnings,
        ),
      );
    }
    return 0;
  }
}

/// Regenerates reports from a results file.
class ReportCommand extends Command<int> {
  ReportCommand() {
    argParser
      ..addOption(
        'output-dir',
        abbr: 'o',
        help:
            'The directory in which to write the reports (default: the '
            'directory containing the results file).',
        valueHelp: 'path',
      )
      ..addFlag('html', defaultsTo: true, help: 'Write report.html.')
      ..addFlag('markdown', defaultsTo: true, help: 'Write report.md.')
      ..addFlag(
        'print',
        negatable: false,
        help: 'Also print the results as tables.',
      )
      ..addFlag(
        'color',
        help: 'Use colors in the output (default: auto-detect).',
      );
  }

  @override
  String get name => 'report';

  @override
  String get description =>
      'Regenerates report.html and report.md from a results.json file.';

  @override
  String get invocation => '${runner!.executableName} report <results.json>';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.length != 1) {
      usageException('Expected one results file.');
    }
    final BenchmarkReport report;
    try {
      report = await _loadReport(args.rest.single);
    } on FormatException catch (e) {
      stderr.writeln('Error: ${e.message}');
      return 1;
    } on FileSystemException catch (e) {
      stderr.writeln('Error: ${e.message}: ${e.path}');
      return 1;
    }
    final console = ConsoleReporter(
      color: args.wasParsed('color') ? args.flag('color') : null,
      interactive: false,
    );
    if (args.flag('print')) {
      for (final scenario in report.scenarios) {
        console.printScenario(ScenarioSummary(report, scenario));
      }
    }
    final outputs = await writeReports(
      report,
      outputDirectory: args.option('output-dir') ?? p.dirname(args.rest.single),
      timestamped: false,
      json: false,
      html: args.flag('html'),
      markdown: args.flag('markdown'),
    );
    if (args.flag('print')) {
      console.printSummary(report, outputs: outputs);
    } else {
      outputs.forEach(stdout.writeln);
    }
    return 0;
  }
}

/// Lists the available scenarios and clients.
class ListCommand extends Command<int> {
  ListCommand() {
    argParser.addFlag(
      'quick',
      abbr: 'q',
      negatable: false,
      help: 'Describe the scenarios as they run with --quick.',
    );
  }

  @override
  String get name => 'list';

  @override
  String get description => 'Lists the scenarios and clients.';

  @override
  Future<int> run() async {
    final scenarios = createScenarios(quick: argResults!.flag('quick'));
    final categories = {for (final scenario in scenarios) scenario.category};
    for (final category in categories) {
      stdout.writeln(category);
      for (final scenario in scenarios) {
        if (scenario.category != category) continue;
        stdout.writeln(
          '  ${scenario.id.padRight(30)} ${scenario.title} '
          '[${scenario.metric.label}]',
        );
      }
      stdout.writeln();
    }
    stdout.writeln('Clients on this platform');
    for (final variant in createClientVariants()) {
      stdout.writeln(
        '  ${variant.name.padRight(22)} ${variant.protocol.label}',
      );
    }
    return 0;
  }
}
