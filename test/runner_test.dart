// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:http_client_benchmarks/http_client_benchmarks.dart';
import 'package:test/test.dart';

/// Runs every scenario once with each client that can run without trusting
/// the benchmark CA, checking that the scenarios execute correctly.
void main() {
  late BenchmarkServer server;
  late Directory certificates;

  setUpAll(() async {
    certificates = await Directory.systemTemp.createTemp('benchmark_certs');
    server = await BenchmarkServer.start(
      certificateDirectory: certificates.path,
    );
  });

  tearDownAll(() async {
    await server.close();
    await certificates.delete(recursive: true);
  });

  test('every scenario runs with every client', () async {
    final variants = selectVariants(
      createClientVariants(caCertificate: server.caCertificate),
      protocols: ['h1c', 'h1', 'h2'],
    ).where((v) => v.client != 'CupertinoClient' || !v.protocol.secure);
    final scenarios = createScenarios(quick: true);
    final configuration = RunConfiguration(
      trials: 1,
      warmup: 0,
      quick: true,
      httpProfiling: false,
    );
    final report = await BenchmarkRunner(
      server: server,
      environment: await Environment.capture(),
      variants: variants.toList(),
      scenarios: scenarios,
      configuration: configuration,
    ).run();

    expect(report.availableVariants, hasLength(variants.length));
    expect(report.results, hasLength(scenarios.length * variants.length));
    for (final result in report.results) {
      expect(
        result.status,
        RunStatus.ok,
        reason:
            '${result.scenarioId} with ${result.variantId}: '
            '${result.message}',
      );
      final variant = report.variant(result.variantId);
      expect(
        result.protocolShare(variant.protocol.serverProtocol),
        1,
        reason: '${result.scenarioId} with ${result.variantId}',
      );
      expect(result.metric!.p50, greaterThanOrEqualTo(0));
    }

    // The reports can be generated from real results.
    expect(htmlReport(report), contains('<svg'));
    expect(markdownReport(report), contains('## Summary'));
  });
}
