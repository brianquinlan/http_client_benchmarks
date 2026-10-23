// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Benchmarks that compare `package:http` `Client` implementations over
/// HTTP/1.1, HTTP/2 and HTTP/3.
///
/// Most users should run the benchmarks from the command line:
///
/// ```shell
/// dart run bin/benchmark.dart run
/// ```
library;

export 'src/android.dart';
export 'src/cli.dart'
    show runCli, selectScenarios, selectVariants, writeReports;
export 'src/clients.dart';
export 'src/compare.dart';
export 'src/device.dart';
export 'src/environment.dart';
export 'src/metric.dart';
export 'src/protocol.dart';
export 'src/reporters/console_reporter.dart' show ConsoleReporter;
export 'src/reporters/html_reporter.dart';
export 'src/reporters/markdown_reporter.dart';
export 'src/results.dart';
export 'src/runner.dart';
export 'src/scenario.dart';
export 'src/scenarios.dart';
export 'src/server.dart';
export 'src/stats.dart';
