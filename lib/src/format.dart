// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'metric.dart';

const _kib = 1024;
const _mib = 1024 * _kib;
const _gib = 1024 * _mib;

/// Formats a size in bytes, e.g. "64 MiB" or "1.5 KiB".
String formatSize(num bytes) {
  String format(num value, String unit) {
    final rounded = value.roundToDouble();
    return value == rounded
        ? '${rounded.toInt()} $unit'
        : '${value.toStringAsFixed(1)} $unit';
  }

  final magnitude = bytes.abs();
  if (magnitude >= _gib) return format(bytes / _gib, 'GiB');
  if (magnitude >= _mib) return format(bytes / _mib, 'MiB');
  if (magnitude >= _kib) return format(bytes / _kib, 'KiB');
  return '${bytes.round()} B';
}

/// Formats a change in size, e.g. "+12.3 MiB".
String formatSizeDelta(num bytes) =>
    bytes < 0 ? '−${formatSize(-bytes)}' : '+${formatSize(bytes)}';

/// Formats a duration given in microseconds, e.g. "812 µs" or "12.3 ms".
String formatMicroseconds(num micros) {
  if (micros < 1000) return '${micros.round()} µs';
  if (micros < 10000) return '${(micros / 1000).toStringAsFixed(2)} ms';
  if (micros < 1000000) return '${(micros / 1000).toStringAsFixed(1)} ms';
  return '${(micros / 1000000).toStringAsFixed(2)} s';
}

/// Formats [value] with thousands separators and [decimals] decimal places.
String formatNumber(num value, {int decimals = 0}) {
  final fixed = value.abs().toStringAsFixed(decimals);
  final [whole, ...fraction] = fixed.split('.');
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buffer.write(',');
    buffer.write(whole[i]);
  }
  if (fraction.isNotEmpty) buffer.write('.${fraction.single}');
  return buffer.toString();
}

/// Formats [value], a value of [metric].
String formatMetric(Metric metric, num value) => switch (metric) {
  Metric.requestsPerSecond => '${formatNumber(value)} req/s',
  Metric.throughput => '${formatNumber(value, decimals: 1)} MB/s',
  Metric.latency ||
  Metric.eventLatency ||
  Metric.cancelLatency => formatMicroseconds(value),
  Metric.peakMemory => formatSizeDelta(value),
  Metric.bufferedBytes => formatSize(value),
};

/// Formats a relative performance, e.g. "0.84×".
String formatRatio(double ratio) => '${ratio.toStringAsFixed(2)}×';

/// Formats a fraction as a percentage, e.g. "12%".
String formatPercent(double fraction, {int decimals = 0}) =>
    '${(fraction * 100).toStringAsFixed(decimals)}%';
