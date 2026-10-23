// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:http_client_benchmarks/http_client_benchmarks.dart';
import 'package:test/test.dart';

void main() {
  group('percentile', () {
    test('interpolates between ranks', () {
      expect(percentile([1, 2, 3, 4], 0), 1);
      expect(percentile([1, 2, 3, 4], 50), 2.5);
      expect(percentile([1, 2, 3, 4], 100), 4);
      expect(percentile([10], 99), 10);
    });

    test('rejects empty samples', () {
      expect(() => percentile([], 50), throwsArgumentError);
    });
  });

  test('median and median absolute deviation', () {
    expect(median([5, 1, 3]), 3);
    // Deviations from the median (3) are [2, 1, 0, 1, 97].
    expect(medianAbsoluteDeviation([1, 2, 3, 4, 100]), 1);
  });

  group('Distribution', () {
    test('summarizes samples', () {
      final distribution = Distribution.of([10, 1, 9, 2, 8, 3, 7, 4, 6, 5]);
      expect(distribution.count, 10);
      expect(distribution.min, 1);
      expect(distribution.max, 10);
      expect(distribution.mean, 5.5);
      expect(distribution.p50, 5.5);
      expect(distribution.p90, closeTo(9.1, 1e-9));
      expect(distribution.standardDeviation, closeTo(3.02765, 1e-5));
      expect(distribution.medianAbsoluteDeviation, 2.5);
      expect(distribution.relativeSpread, closeTo(2.5 / 5.5, 1e-9));
    });

    test('round trips through JSON', () {
      final distribution = Distribution.of([3, 1, 4, 1, 5, 9, 2, 6]);
      final copy = Distribution.fromJson(
        jsonDecode(jsonEncode(distribution.toJson())) as Map<String, Object?>,
      );
      expect(copy.toJson(), distribution.toJson());
    });
  });

  group('mannWhitneyU', () {
    test('computes exact p-values for small samples', () {
      // Of the 20 orderings of two samples of size 3, two have U <= 1.
      final result = mannWhitneyU([1, 2, 4], [3, 5, 6]);
      expect(result.u, 1);
      expect(result.pValue, closeTo(0.2, 1e-12));
    });

    test('detects completely separated samples', () {
      final result = mannWhitneyU(
        [1, 2, 3, 4, 5, 6, 7],
        [8, 9, 10, 11, 12, 13, 14],
      );
      expect(result.u, 0);
      // 2 / C(14, 7)
      expect(result.pValue, closeTo(2 / 3432, 1e-12));
    });

    test('does not flag interleaved samples', () {
      expect(mannWhitneyU([1, 3, 5, 7], [2, 4, 6, 8]).pValue, greaterThan(0.5));
    });

    test('uses a normal approximation with ties', () {
      final result = mannWhitneyU(List.filled(20, 10), List.filled(20, 20));
      expect(result.u, 0);
      expect(result.pValue, lessThan(1e-6));
    });

    test('handles identical samples', () {
      expect(mannWhitneyU([1, 1, 1], [1, 1, 1]).pValue, 1);
    });

    test('uses a normal approximation for large samples', () {
      final a = [for (var i = 0; i < 60; i++) i * 2.0];
      final b = [for (var i = 0; i < 60; i++) i * 2.0 + 41];
      expect(mannWhitneyU(a, b).pValue, lessThan(0.001));
      expect(
        mannWhitneyU(a, [for (final x in a) x + 1]).pValue,
        greaterThan(0.5),
      );
    });
  });

  test('minimumMannWhitneyPValue', () {
    expect(minimumMannWhitneyPValue(1, 1), 1);
    expect(minimumMannWhitneyPValue(3, 3), closeTo(0.1, 1e-12));
    expect(minimumMannWhitneyPValue(3, 4), closeTo(2 / 35, 1e-12));
    expect(minimumMannWhitneyPValue(4, 4), closeTo(2 / 70, 1e-12));
    // It is the p-value of completely separated samples.
    expect(
      mannWhitneyU([1, 2, 3, 4], [5, 6, 7, 8]).pValue,
      closeTo(minimumMannWhitneyPValue(4, 4), 1e-12),
    );
  });

  test('adjustForFalseDiscoveryRate', () {
    // The same as R's p.adjust(c(0.01, 0.04, 0.03, 0.005), method = "BH").
    final adjusted = adjustForFalseDiscoveryRate([0.01, 0.04, 0.03, 0.005]);
    expect(adjusted, hasLength(4));
    expect(adjusted[0], closeTo(0.02, 1e-12));
    expect(adjusted[1], closeTo(0.04, 1e-12));
    expect(adjusted[2], closeTo(0.04, 1e-12));
    expect(adjusted[3], closeTo(0.02, 1e-12));
    expect(adjustForFalseDiscoveryRate([0.5, 0.9]), [0.9, 0.9]);
    expect(adjustForFalseDiscoveryRate([]), isEmpty);
  });

  group('Metric.ratio', () {
    test('higher is better', () {
      expect(Metric.throughput.ratio(50, 100), 0.5);
      expect(Metric.throughput.ratio(100, 100), 1);
    });

    test('lower is better', () {
      expect(Metric.latency.ratio(200, 100), 0.5);
      expect(Metric.latency.ratio(0, 0), 1);
    });

    test('ignores differences below the noise floor', () {
      const mib = 1024.0 * 1024;
      expect(Metric.peakMemory.ratio(mib / 2, mib / 64), 1);
      expect(Metric.peakMemory.ratio(4 * mib, mib / 64), 0.25);
    });
  });
}
