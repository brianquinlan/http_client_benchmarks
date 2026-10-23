// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math' as math;

List<double> _sorted(Iterable<num> values) =>
    [for (final value in values) value.toDouble()]..sort();

/// Returns the [p]th percentile (0-100) of [sorted], which must be sorted in
/// ascending order.
///
/// Interpolates linearly between the closest ranks.
double percentile(List<num> sorted, double p) {
  if (sorted.isEmpty) {
    throw ArgumentError.value(sorted, 'sorted', 'Must not be empty');
  }
  final rank = (p / 100) * (sorted.length - 1);
  final lower = rank.floor();
  final upper = rank.ceil();
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - lower);
}

/// Returns the median of [values].
double median(Iterable<num> values) => percentile(_sorted(values), 50);

/// Returns the median absolute deviation of [values] from their median.
double medianAbsoluteDeviation(Iterable<num> values) {
  final center = median(values);
  return median(values.map((value) => (value - center).abs()));
}

/// The percentiles recorded by [Distribution].
const recordedPercentiles = [50.0, 75.0, 90.0, 95.0, 99.0, 99.9];

/// Summary statistics of a set of samples.
class Distribution {
  Distribution._({
    required this.count,
    required this.min,
    required this.max,
    required this.mean,
    required this.standardDeviation,
    required this.medianAbsoluteDeviation,
    required this.percentiles,
  });

  /// Computes the summary statistics of [values], which must not be empty.
  factory Distribution.of(Iterable<num> values) {
    final sorted = _sorted(values);
    if (sorted.isEmpty) {
      throw ArgumentError.value(values, 'values', 'Must not be empty');
    }
    final mean = sorted.reduce((a, b) => a + b) / sorted.length;
    final squares = sorted.fold<double>(
      0,
      (sum, value) => sum + (value - mean) * (value - mean),
    );
    final center = percentile(sorted, 50);
    return Distribution._(
      count: sorted.length,
      min: sorted.first,
      max: sorted.last,
      mean: mean,
      standardDeviation: sorted.length > 1
          ? math.sqrt(squares / (sorted.length - 1))
          : 0,
      medianAbsoluteDeviation: median(
        sorted.map((value) => (value - center).abs()),
      ),
      percentiles: {
        for (final p in recordedPercentiles) p: percentile(sorted, p),
      },
    );
  }

  factory Distribution.fromJson(Map<String, Object?> json) => Distribution._(
    count: json['count'] as int,
    min: (json['min'] as num).toDouble(),
    max: (json['max'] as num).toDouble(),
    mean: (json['mean'] as num).toDouble(),
    standardDeviation: (json['stddev'] as num).toDouble(),
    medianAbsoluteDeviation: (json['mad'] as num).toDouble(),
    percentiles: {
      for (final MapEntry(:key, :value)
          in (json['percentiles'] as Map<String, Object?>).entries)
        double.parse(key): (value as num).toDouble(),
    },
  );

  final int count;
  final double min;
  final double max;
  final double mean;
  final double standardDeviation;
  final double medianAbsoluteDeviation;

  /// The values at each of [recordedPercentiles].
  final Map<double, double> percentiles;

  double get p50 => percentiles[50]!;
  double get p90 => percentiles[90]!;
  double get p99 => percentiles[99]!;

  /// The median absolute deviation as a fraction of the median.
  double get relativeSpread => p50 == 0 ? 0 : medianAbsoluteDeviation / p50;

  Map<String, Object?> toJson() => {
    'count': count,
    'min': min,
    'max': max,
    'mean': mean,
    'stddev': standardDeviation,
    'mad': medianAbsoluteDeviation,
    'percentiles': {
      for (final MapEntry(:key, :value) in percentiles.entries)
        _formatPercentile(key): value,
    },
  };
}

String _formatPercentile(double p) =>
    p == p.roundToDouble() ? p.toInt().toString() : p.toString();

/// The result of a Mann-Whitney U test.
class MannWhitneyResult {
  const MannWhitneyResult(this.u, this.pValue);

  /// The U statistic (the smaller of U₁ and U₂).
  final double u;

  /// The two-sided p-value.
  final double pValue;
}

/// Performs a two-sided Mann-Whitney U test, which checks whether samples
/// [a] and [b] are likely to come from the same distribution.
///
/// The p-value is exact when there are no ties and the samples are small,
/// and otherwise uses a normal approximation with tie and continuity
/// corrections.
MannWhitneyResult mannWhitneyU(List<num> a, List<num> b) {
  final n1 = a.length;
  final n2 = b.length;
  if (n1 == 0 || n2 == 0) {
    throw ArgumentError('Both samples must be non-empty');
  }
  final combined = [
    for (final value in a) (value.toDouble(), true),
    for (final value in b) (value.toDouble(), false),
  ]..sort((x, y) => x.$1.compareTo(y.$1));

  // Assign ranks, averaging the ranks of tied values.
  var rankSumA = 0.0;
  var tieCorrection = 0.0;
  for (var i = 0; i < combined.length;) {
    var j = i;
    while (j + 1 < combined.length && combined[j + 1].$1 == combined[i].$1) {
      j++;
    }
    final rank = (i + j) / 2 + 1;
    for (var k = i; k <= j; k++) {
      if (combined[k].$2) rankSumA += rank;
    }
    final ties = j - i + 1;
    tieCorrection += ties * ties * ties - ties;
    i = j + 1;
  }
  final u1 = rankSumA - n1 * (n1 + 1) / 2;
  final u = math.min(u1, n1 * n2 - u1);

  if (tieCorrection == 0 && n1 <= 50 && n2 <= 50) {
    return MannWhitneyResult(u, math.min(1, 2 * _exactCdf(n1, n2, u.round())));
  }
  final n = n1 + n2;
  final variance = n1 * n2 / 12 * ((n + 1) - tieCorrection / (n * (n - 1)));
  if (variance <= 0) return MannWhitneyResult(u, 1);
  final z = math.max(0, (n1 * n2 / 2 - u).abs() - 0.5) / math.sqrt(variance);
  return MannWhitneyResult(u, math.min(1, _erfc(z / math.sqrt2)));
}

/// The smallest p-value that [mannWhitneyU] can return for samples of size
/// [n1] and [n2] without ties, which occurs when every value in one sample
/// is smaller than every value in the other.
///
/// If this is not below the significance level then no difference between
/// the samples, however large, can be reliably detected.
double minimumMannWhitneyPValue(int n1, int n2) {
  // P(U = 0) = 1 / C(n1 + n2, n1).
  var orderings = 1.0;
  for (var i = 1; i <= n1; i++) {
    orderings = orderings * (n2 + i) / i;
  }
  return math.min(1, 2 / orderings);
}

/// Adjusts [pValues] for multiple comparisons using the Benjamini-Hochberg
/// procedure, which controls the expected proportion of false positives
/// among the results that are reported as significant.
List<double> adjustForFalseDiscoveryRate(List<double> pValues) {
  final count = pValues.length;
  final order = [for (var i = 0; i < count; i++) i]
    ..sort((a, b) => pValues[a].compareTo(pValues[b]));
  final adjusted = List<double>.filled(count, 1);
  var smallest = 1.0;
  for (var rank = count; rank >= 1; rank--) {
    final index = order[rank - 1];
    smallest = math.min(smallest, pValues[index] * count / rank);
    adjusted[index] = smallest;
  }
  return adjusted;
}

/// Returns P(U ≤ [u]) for samples of size [n1] and [n2] without ties.
double _exactCdf(int n1, int n2, int u) {
  // counts[j][k] is the number of orderings of i elements of the first sample
  // and j elements of the second sample for which U = k. Rows are computed
  // for increasing i using f(i, j, k) = f(i - 1, j, k - j) + f(i, j - 1, k).
  var previous = [
    for (var j = 0; j <= n2; j++) [1.0],
  ];
  for (var i = 1; i <= n1; i++) {
    final current = <List<double>>[];
    for (var j = 0; j <= n2; j++) {
      final counts = List<double>.filled(i * j + 1, 0);
      final above = previous[j];
      for (var k = 0; k < above.length; k++) {
        counts[k + j] += above[k];
      }
      if (j > 0) {
        final left = current[j - 1];
        for (var k = 0; k < left.length; k++) {
          counts[k] += left[k];
        }
      }
      current.add(counts);
    }
    previous = current;
  }
  final counts = previous[n2];
  final total = counts.reduce((a, b) => a + b);
  var cumulative = 0.0;
  for (var k = 0; k <= u && k < counts.length; k++) {
    cumulative += counts[k];
  }
  return cumulative / total;
}

// Coefficients of the polynomial used by [_erfc], lowest order first.
const _erfcCoefficients = [
  -1.26551223,
  1.00002368,
  0.37409196,
  0.09678418,
  -0.18628806,
  0.27886807,
  -1.13520398,
  1.48851587,
  -0.82215223,
  0.17087277,
];

/// The complementary error function (fractional error < 1.2e-7).
///
/// See "Numerical Recipes in C", section 6.2.
double _erfc(double x) {
  final z = x.abs();
  final t = 1 / (1 + 0.5 * z);
  var polynomial = 0.0;
  for (final coefficient in _erfcCoefficients.reversed) {
    polynomial = polynomial * t + coefficient;
  }
  final r = t * math.exp(-z * z + polynomial);
  return x >= 0 ? r : 2 - r;
}
