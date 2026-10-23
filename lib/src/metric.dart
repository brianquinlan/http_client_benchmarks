// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math' as math;

/// The primary measurement of a scenario, computed once per trial.
enum Metric {
  /// Completed requests per second.
  requestsPerSecond('Requests/s', higherIsBetter: true),

  /// Payload bytes sent and received per second, in MB/s (10⁶ bytes/s).
  throughput('Throughput', higherIsBetter: true),

  /// The median of the "latency" samples, in microseconds.
  latency('Median latency', sample: 'latency'),

  /// The median of the "event" samples (the time between the server sending
  /// an event and the client receiving it), in microseconds.
  eventLatency('Median event delay', sample: 'event', noiseFloor: 50),

  /// The median of the "recovery" samples (the time from cancelling a
  /// response stream until a following request completes), in microseconds.
  cancelLatency(
    'Median cancel + next request',
    sample: 'recovery',
    noiseFloor: 50,
  ),

  /// The growth of the process's resident set size during the trial, in
  /// bytes.
  peakMemory('Peak RSS growth', noiseFloor: 1024 * 1024),

  /// The number of response body bytes that the server had sent but the
  /// application had not consumed, measured by the scenario while the
  /// application was not reading the response.
  ///
  /// Even when a client applies backpressure, the operating system's socket
  /// buffers and the protocol's flow-control windows can hold several MiB, so
  /// smaller differences are not meaningful.
  bufferedBytes('Buffered while paused', noiseFloor: 8 * 1024 * 1024);

  const Metric(
    this.label, {
    this.higherIsBetter = false,
    this.sample,
    this.noiseFloor = 0,
  });

  /// A short, human-readable description.
  final String label;

  /// Whether larger values are better.
  final bool higherIsBetter;

  /// The name of the samples that the metric summarizes, if any.
  final String? sample;

  /// Values below this are treated as equal when computing [ratio], because
  /// differences between them are dominated by measurement noise.
  final double noiseFloor;

  /// Whether the metric measures resource usage rather than speed.
  bool get measuresMemory => this == peakMemory || this == bufferedBytes;

  /// Returns how [value] compares with [best]: a number in (0, 1], where 1
  /// means [value] is (equivalent to) the best.
  double ratio(double value, double best) {
    if (value == best) return 1;
    if (higherIsBetter) return best == 0 ? 0 : value / best;
    final denominator = math.max(value, noiseFloor);
    return denominator == 0 ? 1 : math.max(best, noiseFloor) / denominator;
  }

  /// Whether [a] is better than [b].
  bool isBetter(double a, double b) => higherIsBetter ? a > b : a < b;
}
