// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:flutter/material.dart';

/// The benchmarks run in `integration_test/benchmark_test.dart`, which the
/// benchmark command-line tool starts with `flutter drive`; this app only
/// explains that.
void main() {
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Run the benchmarks from a computer connected to this device '
              'with:\n\n'
              'dart run bin/benchmark.dart run --device <serial>',
            ),
          ),
        ),
      ),
    ),
  );
}
