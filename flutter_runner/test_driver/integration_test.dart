// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Writes the results reported by `integration_test/benchmark_test.dart` to
/// the file named by the `BENCHMARK_RESULTS` environment variable, which the
/// benchmark command-line tool sets.
Future<void> main() => integrationDriver(
  // A full run on a slow device can take a long time.
  timeout: const Duration(hours: 12),
  responseDataCallback: (data) async {
    await File(
      Platform.environment['BENCHMARK_RESULTS']!,
    ).writeAsString(jsonEncode(data!['report']));
  },
);
