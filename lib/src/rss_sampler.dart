// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

/// Tracks the peak resident set size (RSS) of this process.
///
/// Sampling happens in a separate isolate so that peaks are observed even
/// while the main isolate is busy (e.g. copying a large request body). The
/// isolate shares the main isolate's heap, so it cannot sample during
/// garbage collection pauses.
class RssSampler {
  RssSampler._(this._isolate, this._commands);

  final Isolate _isolate;
  final SendPort _commands;

  /// Starts sampling the RSS every [interval].
  static Future<RssSampler> start({
    Duration interval = const Duration(milliseconds: 5),
  }) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_sample, (
      ready.sendPort,
      interval.inMicroseconds,
    ), debugName: 'RssSampler');
    final commands = await ready.first as SendPort;
    return RssSampler._(isolate, commands);
  }

  /// Starts a new measurement window and returns the current RSS, in bytes.
  Future<int> reset() => _send('reset');

  /// Returns the peak RSS, in bytes, since the last call to [reset].
  Future<int> peak() => _send('peak');

  Future<int> _send(String command) async {
    final reply = ReceivePort();
    _commands.send((command, reply.sendPort));
    return await reply.first as int;
  }

  /// Stops sampling.
  void close() => _isolate.kill(priority: Isolate.immediate);
}

void _sample((SendPort, int) arguments) {
  final (ready, intervalMicroseconds) = arguments;
  final commands = ReceivePort();
  ready.send(commands.sendPort);

  var peak = ProcessInfo.currentRss;
  Timer.periodic(Duration(microseconds: intervalMicroseconds), (_) {
    final rss = ProcessInfo.currentRss;
    if (rss > peak) peak = rss;
  });
  commands.listen((message) {
    final (command, reply) = message as (String, SendPort);
    final rss = ProcessInfo.currentRss;
    if (command == 'reset') {
      peak = rss;
      reply.send(rss);
    } else {
      if (rss > peak) peak = rss;
      reply.send(peak);
    }
  });
}
