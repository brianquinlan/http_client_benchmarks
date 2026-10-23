// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_runner/android_clients.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_client_benchmarks/http_client_benchmarks.dart';
import 'package:integration_test/integration_test.dart';

/// Runs the benchmarks described by the `BENCHMARK_CONFIG` define and
/// reports the results to `test_driver/integration_test.dart`.
///
/// The benchmark command-line tool runs this with `flutter drive` (see
/// `runFlutterRunner`), after starting the benchmark server on the device.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('benchmarks', (tester) async {
    const encoded = String.fromEnvironment('BENCHMARK_CONFIG');
    if (encoded.isEmpty) {
      fail(
        'Run the benchmarks with: '
        'dart run bin/benchmark.dart run --device <serial>',
      );
    }
    final config = DeviceRunConfig.decode(encoded);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('Running the benchmarks…'))),
      ),
    );
    final report = await runOnDevice(
      config,
      createPlatformVariants: createAndroidClientVariants,
      listener: _ProgressPrinter(config.scenarioIds.length),
    );
    binding.reportData = {'report': report.toJson()};
  }, timeout: Timeout.none);
}

/// Prints the progress of the benchmarks, which `flutter drive` shows.
///
/// The results are printed by the command-line tool once they have been
/// reported.
class _ProgressPrinter implements RunnerListener {
  _ProgressPrinter(this._scenarioCount);

  final int _scenarioCount;
  var _scenarioIndex = 0;

  @override
  void onVariantChecked(VariantInfo variant) {
    print(
      variant.available
          ? '✓ ${variant.name}'
          : '✗ ${variant.name}: ${variant.unavailableReason}',
    );
  }

  @override
  void onVariantsChecked(List<VariantInfo> variants) {}

  @override
  void onScenarioStarted(Scenario scenario) {
    _scenarioIndex++;
    print('[$_scenarioIndex/$_scenarioCount] ${scenario.id}');
  }

  @override
  void onRunStarted(Scenario scenario, ClientVariant variant) {
    print('  ${variant.name}');
  }

  @override
  void onScenarioFinished(Scenario scenario, List<RunResult> results) {
    for (final result in results) {
      if (result.status != RunStatus.ok) {
        print(
          '  ${result.variantId}: ${result.status.name}: ${result.message}',
        );
      }
    }
  }
}
