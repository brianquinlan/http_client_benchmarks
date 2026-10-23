// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:http_client_benchmarks/src/format.dart';
import 'package:http_client_benchmarks/src/metric.dart';
import 'package:test/test.dart';

void main() {
  test('formatSize', () {
    expect(formatSize(512), '512 B');
    expect(formatSize(1024), '1 KiB');
    expect(formatSize(1536), '1.5 KiB');
    expect(formatSize(64 * 1024 * 1024), '64 MiB');
    expect(formatSize(1 << 30), '1 GiB');
  });

  test('formatSizeDelta', () {
    expect(formatSizeDelta(0), '+0 B');
    expect(formatSizeDelta(2048), '+2 KiB');
    expect(formatSizeDelta(-2048), '−2 KiB');
  });

  test('formatMicroseconds', () {
    expect(formatMicroseconds(812), '812 µs');
    expect(formatMicroseconds(1234), '1.23 ms');
    expect(formatMicroseconds(12345), '12.3 ms');
    expect(formatMicroseconds(1234567), '1.23 s');
  });

  test('formatNumber', () {
    expect(formatNumber(0), '0');
    expect(formatNumber(999), '999');
    expect(formatNumber(1000), '1,000');
    expect(formatNumber(1234567.891, decimals: 2), '1,234,567.89');
    expect(formatNumber(-12345), '-12,345');
  });

  test('formatMetric', () {
    expect(formatMetric(Metric.requestsPerSecond, 18234.4), '18,234 req/s');
    expect(formatMetric(Metric.throughput, 1234.56), '1,234.6 MB/s');
    expect(formatMetric(Metric.latency, 6810), '6.81 ms');
    expect(formatMetric(Metric.peakMemory, 3 * 1024 * 1024), '+3 MiB');
  });

  test('formatRatio and formatPercent', () {
    expect(formatRatio(0.8412), '0.84×');
    expect(formatPercent(0.123), '12%');
    expect(formatPercent(-0.0512, decimals: 1), '-5.1%');
  });
}
