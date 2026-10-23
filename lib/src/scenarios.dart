// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart';

import 'format.dart';
import 'metric.dart';
import 'scenario.dart';
import 'stats.dart';

const _kib = 1024;
const _mib = 1024 * _kib;

/// The names of the scenario categories.
abstract final class Categories {
  static const concurrency = 'Concurrency';
  static const downloads = 'Downloads';
  static const uploads = 'Uploads';
  static const connections = 'Connections';
  static const payloads = 'Payloads';
}

/// Returns the standard set of scenarios.
///
/// If [quick] is true then request counts and payload sizes are reduced so
/// that the scenarios run quickly, e.g. as a smoke test.
List<Scenario> createScenarios({bool quick = false}) {
  int pick(int full, int reduced) => quick ? reduced : full;
  // Request-rate scenarios run for at least this long, however fast the
  // client, so that their results are stable.
  final minDuration = Duration(milliseconds: pick(500, 100));
  return [
    GetScenario(
      id: 'get-sequential',
      count: pick(200, 50),
      concurrency: 1,
      metric: Metric.latency,
    ),
    GetScenario(
      id: 'get-concurrent-16',
      count: pick(1600, 320),
      concurrency: 16,
      minDuration: minDuration,
    ),
    GetScenario(
      id: 'get-concurrent-128',
      count: pick(3840, 768),
      concurrency: 128,
      minDuration: minDuration,
    ),
    GetScenario(
      id: 'get-delayed-concurrent-100',
      count: pick(400, 200),
      concurrency: 100,
      delayMilliseconds: 20,
      minDuration: minDuration,
    ),
    GetScenario(
      id: 'get-multi-origin-64',
      count: pick(1280, 256),
      concurrency: 64,
      originCount: 4,
      minDuration: minDuration,
    ),
    HeadOfLineScenario(fastCount: pick(60, 30)),
    DownloadScenario(
      id: 'download-1mib-sequential',
      count: pick(20, 10),
      size: _mib,
    ),
    DownloadScenario(id: 'download-large', size: pick(64, 16) * _mib),
    DownloadScenario(
      id: 'download-concurrent',
      count: 8,
      concurrency: 8,
      size: pick(8, 2) * _mib,
    ),
    DownloadScenario(
      id: 'download-small-writes',
      size: pick(16, 4) * _mib,
      writeSize: 16 * _kib,
    ),
    ServerSentEventsScenario(events: pick(200, 50)),
    SlowConsumerScenario(
      size: pick(64, 16) * _mib,
      pause: Duration(milliseconds: pick(1000, 500)),
    ),
    CancelScenario(count: pick(10, 5)),
    UploadScenario(
      id: 'upload-1mib-sequential',
      count: pick(20, 10),
      size: _mib,
    ),
    UploadScenario(id: 'upload-large-buffered', size: pick(64, 16) * _mib),
    UploadScenario(
      id: 'upload-large-streamed',
      size: pick(64, 16) * _mib,
      chunkSize: 64 * _kib,
    ),
    UploadScenario(
      id: 'upload-streamed-small-chunks',
      size: pick(16, 4) * _mib,
      chunkSize: _kib,
    ),
    UploadScenario(
      id: 'upload-concurrent',
      count: 8,
      concurrency: 8,
      size: pick(8, 2) * _mib,
    ),
    MultipartScenario(count: pick(10, 5), fileSize: pick(4, 1) * _mib),
    ColdClientScenario(count: pick(10, 5)),
    HeadersScenario(count: pick(200, 50)),
    JsonBurstScenario(bursts: pick(10, 4)),
    GzipScenario(count: pick(5, 3), size: pick(8, 2) * _mib),
  ];
}

/// Sends GET requests for small responses, optionally concurrently and
/// across several origins.
class GetScenario extends Scenario {
  GetScenario({
    required this.id,
    required this.count,
    required this.concurrency,
    this.size = _kib,
    this.delayMilliseconds = 0,
    this.originCount = 1,
    this.metric = Metric.requestsPerSecond,
    this.minDuration = Duration.zero,
  });

  @override
  final String id;

  /// The minimum number of requests per trial.
  final int count;

  /// The maximum number of requests in flight.
  final int concurrency;

  /// The size of each response body.
  final int size;

  /// How long the server waits before responding.
  final int delayMilliseconds;

  /// The number of origins that requests are spread across.
  final int originCount;

  @override
  final Metric metric;

  /// The minimum duration of a trial: requests continue to be sent until
  /// both [count] requests have been sent and this much time has passed.
  final Duration minDuration;

  @override
  String get category => Categories.concurrency;

  @override
  int get origins => originCount;

  @override
  String get title {
    final buffer = StringBuffer(
      concurrency == 1 ? 'Sequential GETs' : '$concurrency concurrent GETs',
    )..write(' of ${formatSize(size)}');
    if (delayMilliseconds > 0) {
      buffer.write(' with a $delayMilliseconds ms server delay');
    }
    if (originCount > 1) buffer.write(' across $originCount origins');
    return buffer.toString();
  }

  @override
  String get description {
    final buffer = StringBuffer(
      minDuration > Duration.zero
          ? 'Sends GET requests for ${formatSize(size)} responses (at least '
                '$count, for at least ${minDuration.inMilliseconds} ms)'
          : 'Sends $count GET requests for ${formatSize(size)} responses',
    );
    if (concurrency == 1) {
      buffer.write(
        ', one at a time. Measures the overhead that the client adds to '
        'each request, including any bridging to native code.',
      );
    } else {
      final spread = originCount > 1
          ? ', spread across $originCount origins (ports)'
          : '';
      buffer.write(
        ' with $concurrency in flight at a time$spread. Measures how '
        'efficiently the client handles concurrent requests through '
        'connection pooling or stream multiplexing.',
      );
    }
    if (delayMilliseconds > 0) {
      final ideal = formatNumber(concurrency * 1000 / delayMilliseconds);
      buffer.write(
        ' The server waits $delayMilliseconds ms before each response, so the '
        'ideal throughput is $ideal requests/s; clients that limit the number '
        'of connections per host fall well short of it.',
      );
    }
    return buffer.toString();
  }

  @override
  Future<void> run(ScenarioContext context, TrialRecorder recorder) {
    final uris = [
      for (var origin = 0; origin < originCount; origin++)
        context.uri(
          '/bytes',
          query: {
            'size': size,
            if (delayMilliseconds > 0) 'delay_ms': delayMilliseconds,
          },
          origin: origin,
        ),
    ];
    return runConcurrently(
      count,
      concurrency,
      (i) => timedSend(
        context,
        recorder,
        Request('GET', uris[i % originCount]),
        expectedLength: size,
      ),
      minDuration: minDuration,
    );
  }
}

/// Measures the latency of small requests while slow requests are in flight.
class HeadOfLineScenario extends Scenario {
  HeadOfLineScenario({required this.fastCount});

  /// The number of small requests per trial.
  final int fastCount;

  static const _slowCount = 6;
  static const _slowSize = _mib;
  static const _slowDelayMilliseconds = 300;

  @override
  String get id => 'head-of-line';

  @override
  String get category => Categories.concurrency;

  @override
  Metric get metric => Metric.latency;

  @override
  String get title => '$fastCount small GETs behind $_slowCount slow responses';

  @override
  String get description =>
      'Starts $_slowCount slow requests (the server waits '
      '$_slowDelayMilliseconds ms before sending ${formatSize(_slowSize)}) '
      'and then, while they are outstanding, sends $fastCount small GETs to '
      'the same origin at once, like an app making a batch of API calls while '
      'slow requests are pending. Measures the latency of the small requests: '
      'clients that queue requests behind busy connections (e.g. HTTP/1.1 '
      'with a per-host connection limit) show much higher latency than '
      'clients that open more connections or multiplex requests.';

  @override
  Future<void> run(ScenarioContext context, TrialRecorder recorder) async {
    final slowUri = context.uri(
      '/bytes',
      query: {'size': _slowSize, 'delay_ms': _slowDelayMilliseconds},
    );
    final fastUri = context.uri('/bytes', query: {'size': _kib});
    final slow = Future.wait([
      for (var i = 0; i < _slowCount; i++)
        timedSend(
          context,
          recorder,
          Request('GET', slowUri),
          expectedLength: _slowSize,
          record: false,
        ),
    ]);
    // Give the slow requests time to be sent before the fast ones.
    final fast = Future<void>.delayed(
      const Duration(milliseconds: 20),
      () => Future.wait([
        for (var i = 0; i < fastCount; i++)
          timedSend(
            context,
            recorder,
            Request('GET', fastUri),
            expectedLength: _kib,
          ),
      ], eagerError: true),
    );
    await Future.wait([slow, fast], eagerError: true);
  }
}

/// Downloads large responses.
class DownloadScenario extends Scenario {
  DownloadScenario({
    required this.id,
    required this.size,
    this.count = 1,
    this.concurrency = 1,
    this.writeSize,
  });

  @override
  final String id;

  /// The size of each response body.
  final int size;

  /// The number of downloads per trial.
  final int count;

  /// The maximum number of downloads in progress.
  final int concurrency;

  /// The number of bytes that the server writes at a time, or `null` for
  /// the server's default (1 MiB).
  final int? writeSize;

  @override
  String get category => Categories.downloads;

  @override
  Metric get metric => Metric.throughput;

  @override
  String get title {
    if (writeSize case final writeSize?) {
      return 'Download ${formatSize(size)} written in ${formatSize(writeSize)} '
          'pieces';
    }
    if (count == 1) return 'Download ${formatSize(size)}';
    final mode = concurrency == 1 ? 'sequential' : 'concurrent';
    return '$count $mode downloads of ${formatSize(size)}';
  }

  @override
  String get description {
    if (writeSize case final writeSize?) {
      return 'Downloads a ${formatSize(size)} response that the server writes '
          '${formatSize(writeSize)} at a time (rather than 1 MiB at a time), '
          'as streaming servers and proxies often do. The data usually '
          'arrives in more, smaller pieces, which exposes per-frame and '
          'per-read overhead in the client.';
    }
    if (count == 1) {
      return 'Downloads a single ${formatSize(size)} response as a stream. '
          'Measures raw download throughput, including the cost of moving '
          'data from the network stack into Dart.';
    }
    if (concurrency == 1) {
      return 'Downloads $count ${formatSize(size)} responses, one at a time, '
          'over a warm connection.';
    }
    return 'Downloads $count ${formatSize(size)} responses at the same time. '
        'With HTTP/2 and HTTP/3 the downloads usually share a connection, so '
        'flow control and stream scheduling matter.';
  }

  @override
  Future<void> run(ScenarioContext context, TrialRecorder recorder) {
    final uri = context.uri(
      '/bytes',
      query: {'size': size, 'write_size': ?writeSize},
    );
    return runConcurrently(
      count,
      concurrency,
      (_) => timedSend(
        context,
        recorder,
        Request('GET', uri),
        expectedLength: size,
      ),
    );
  }
}

/// Streams server-sent events and measures how quickly each is delivered.
class ServerSentEventsScenario extends Scenario {
  ServerSentEventsScenario({
    required this.events,
    this.eventSize = 256,
    this.interval = const Duration(milliseconds: 2),
  });

  /// The number of events per trial.
  final int events;

  /// The size of each event, in bytes.
  final int eventSize;

  /// The time between events.
  final Duration interval;

  @override
  String get id => 'server-sent-events';

  @override
  String get category => Categories.downloads;

  @override
  Metric get metric => Metric.eventLatency;

  @override
  String get title => 'Stream $events server-sent events';

  @override
  String get description =>
      'Streams $events server-sent events of ${formatSize(eventSize)}, one '
      'every ${interval.inMilliseconds} ms, like an LLM streaming tokens. '
      'Measures the delay between the server writing each event and the '
      'client delivering it to Dart, which reveals buffering in the client.';

  @override
  Future<void> run(ScenarioContext context, TrialRecorder recorder) async {
    final request = Request(
      'GET',
      context.uri(
        '/sse',
        query: {
          'events': events,
          'size': eventSize,
          'interval_us': interval.inMicroseconds,
        },
      ),
    );
    final stopwatch = Stopwatch()..start();
    final response = await context.client.send(request);
    recorder.addSample('ttfb', stopwatch.elapsedMicroseconds);
    checkResponse(request, response);

    var bytes = 0;
    var received = 0;
    final lines = response.stream
        .map((chunk) {
          bytes += chunk.length;
          return chunk;
        })
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data: ')) continue;
      final now = DateTime.now().microsecondsSinceEpoch;
      // "data: <sequence number> <time sent in microseconds> <padding>"
      final sentAt = int.parse(line.split(' ')[2]);
      recorder.addSample('event', math.max(0, now - sentAt));
      received++;
    }
    if (received != events) {
      throw BenchmarkException('Expected $events events, received $received');
    }
    recorder
      ..addSample('latency', stopwatch.elapsedMicroseconds)
      ..operations += 1
      ..bytesReceived += bytes
      ..addResponse(response);
  }
}

/// Downloads a large response while consuming it slowly.
class SlowConsumerScenario extends Scenario {
  SlowConsumerScenario({required this.size, required this.pause});

  /// The size of the response body.
  final int size;

  /// How long the response stream is paused after the first chunk.
  final Duration pause;

  @override
  String get id => 'download-slow-consumer';

  @override
  String get category => Categories.downloads;

  @override
  Metric get metric => Metric.bufferedBytes;

  @override
  int get maxTrials => 5;

  @override
  int get maxWarmup => 1;

  @override
  String get title => 'Download ${formatSize(size)} with a slow consumer';

  @override
  String get description =>
      'Downloads ${formatSize(size)} but pauses the response stream for '
      '${pause.inMilliseconds} ms after the first chunk, like an app writing '
      'to slow storage. At the end of the pause, measures how much of the '
      'response the server has sent but the app has not yet received: '
      'clients that apply backpressure stop reading from the network, so the '
      'server can only fill the socket buffers and flow-control windows, '
      'whereas clients without backpressure buffer the rest of the response '
      'in memory.';

  @override
  Future<void> run(ScenarioContext context, TrialRecorder recorder) async {
    final id = uniqueId();
    final request = Request(
      'GET',
      context.uri('/bytes', query: {'size': size, 'id': id}),
    );
    final stopwatch = Stopwatch()..start();
    final response = await context.client.send(request);
    recorder.addSample('ttfb', stopwatch.elapsedMicroseconds);
    checkResponse(request, response);

    var received = 0;
    int? buffered;
    Future<void> measureWhilePaused() async {
      await Future<void>.delayed(pause);
      // The subscription is paused, so `received` cannot change here.
      final sent = await context.server.progress(id);
      if (sent == null) {
        throw BenchmarkException('The server did not report its progress');
      }
      // The server counts completed writes, so this can be up to one write
      // (1 MiB) too low.
      buffered = math.max(0, sent - received);
    }

    Future<void>? measurement;
    final done = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    subscription = response.stream.listen(
      (chunk) {
        if (received == 0) {
          measurement = measureWhilePaused();
          // Resume even if the measurement fails; its error is reported
          // below.
          subscription.pause(measurement!.then((_) {}, onError: (Object _) {}));
        }
        received += chunk.length;
      },
      onError: done.completeError,
      onDone: done.complete,
      cancelOnError: true,
    );
    await done.future;
    await measurement;
    if (received != size) {
      throw BenchmarkException('Expected $size bytes, received $received');
    }
    if (buffered == null) {
      throw BenchmarkException('The response stream was not paused');
    }
    recorder
      ..addSample('latency', stopwatch.elapsedMicroseconds)
      ..operations += 1
      ..bytesReceived += received
      ..value = buffered!.toDouble()
      ..addResponse(response);
  }
}

/// Cancels downloads part way through.
class CancelScenario extends Scenario {
  CancelScenario({required this.count, this.threshold = 256 * _kib});

  /// The number of downloads per trial.
  final int count;

  /// The number of bytes received before the download is cancelled.
  final int threshold;

  static const _responseSize = 1 << 30;

  @override
  String get id => 'download-cancel';

  @override
  String get category => Categories.downloads;

  @override
  Metric get metric => Metric.cancelLatency;

  @override
  String get title => 'Cancel $count downloads after ${formatSize(threshold)}';

  @override
  String get description =>
      'Starts downloading a ${formatSize(_responseSize)} response, cancels '
      'the response stream after receiving ${formatSize(threshold)} and then '
      'immediately requests ${formatSize(_kib)}, $count times, like an app '
      'abandoning an image that scrolled out of view and loading the next '
      'one. Measures the time from cancelling the stream until the next '
      'response has been received. This includes the cost of stopping the '
      'transfer and, for HTTP/1.1 (which cannot reuse a connection that has '
      'an unfinished response), of opening a new connection.';

  @override
  Future<void> run(ScenarioContext context, TrialRecorder recorder) async {
    final nextUri = context.uri('/bytes', query: {'size': _kib});
    final cancelTimes = <int>[];
    final unread = <int>[];
    for (var i = 0; i < count; i++) {
      final id = uniqueId();
      final request = Request(
        'GET',
        context.uri('/bytes', query: {'size': _responseSize, 'id': id}),
      );
      final stopwatch = Stopwatch()..start();
      final response = await context.client.send(request);
      recorder.addSample('ttfb', stopwatch.elapsedMicroseconds);
      checkResponse(request, response);

      var received = 0;
      final reached = Completer<void>();
      final subscription = response.stream.listen(
        (chunk) {
          received += chunk.length;
          if (received >= threshold && !reached.isCompleted) {
            reached.complete();
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!reached.isCompleted) reached.completeError(error, stackTrace);
        },
        onDone: () {
          if (!reached.isCompleted) {
            reached.completeError(
              BenchmarkException('The response ended before it was cancelled'),
            );
          }
        },
      );
      await reached.future;
      final cancelStarted = stopwatch.elapsedMicroseconds;
      await subscription.cancel();
      final cancelled = stopwatch.elapsedMicroseconds;
      await timedSend(
        context,
        recorder,
        Request('GET', nextUri),
        expectedLength: _kib,
        record: false,
      );
      final recovered = stopwatch.elapsedMicroseconds;
      recorder
        ..addSample('cancel', cancelled - cancelStarted)
        ..addSample('recovery', recovered - cancelStarted)
        ..addSample('latency', recovered)
        ..operations += 1
        ..bytesReceived += received
        ..addResponse(response);
      cancelTimes.add(cancelled - cancelStarted);
      // The server counts completed writes, so this is a lower bound.
      if (await context.server.progress(id) case final sent?) {
        unread.add(math.max(0, sent - received));
      }
    }
    final unreadMedian = unread.isEmpty ? 0 : median(unread);
    recorder.notes['cancel'] =
        'cancel() completed in a median of '
        '${formatMicroseconds(median(cancelTimes))}'
        '${unreadMedian == 0 ? '' : ', and the server had sent at least '
                  '${formatSize(unreadMedian)} (median) that was never read'}.';
  }
}

/// A request whose body is generated, one chunk at a time, as the client
/// reads it.
///
/// This mimics streaming a file from disk: a chunk is only produced when the
/// client is ready for it, so the producer never holds the whole body in
/// memory. Like a file read, each chunk is a new buffer.
class GeneratedBodyRequest extends BaseRequest {
  GeneratedBodyRequest(
    super.method,
    super.url, {
    required Uint8List chunk,
    required int chunkCount,
    this.onBodyRead,
  }) : _chunk = chunk,
       _chunkCount = chunkCount {
    contentLength = chunk.length * chunkCount;
  }

  final Uint8List _chunk;
  final int _chunkCount;

  /// Called when the client has read the entire body.
  final void Function()? onBodyRead;

  @override
  ByteStream finalize() {
    super.finalize();
    return ByteStream(_generate());
  }

  Stream<List<int>> _generate() async* {
    for (var i = 0; i < _chunkCount; i++) {
      yield Uint8List.fromList(_chunk);
    }
    onBodyRead?.call();
  }
}

/// Sends [request] (with a body of [size] bytes) to the "/discard" endpoint
/// and checks that the server received the entire body.
Future<void> timedUpload(
  ScenarioContext context,
  TrialRecorder recorder,
  BaseRequest request,
  int size,
) async {
  final result = await timedSend(
    context,
    recorder,
    request,
    requestBytes: size,
    keepBody: true,
    countReceived: false,
  );
  final received = int.tryParse(utf8.decode(result.body!));
  if (received != size) {
    throw BenchmarkException(
      'The server received $received bytes but $size bytes were sent',
    );
  }
}

/// Uploads request bodies, either from memory or as a stream.
class UploadScenario extends Scenario {
  UploadScenario({
    required this.id,
    required this.size,
    this.count = 1,
    this.concurrency = 1,
    this.chunkSize,
  });

  @override
  final String id;

  /// The size of each request body.
  final int size;

  /// The number of uploads per trial.
  final int count;

  /// The maximum number of uploads in progress.
  final int concurrency;

  /// The size of each chunk of a streamed body, or `null` if the body is
  /// sent from memory using [Request.bodyBytes].
  final int? chunkSize;

  Uint8List? _payload;

  @override
  String get category => Categories.uploads;

  @override
  Metric get metric => Metric.throughput;

  @override
  String get title {
    if (chunkSize case final chunkSize?) {
      return 'Stream a ${formatSize(size)} upload in ${formatSize(chunkSize)} '
          'chunks';
    }
    if (count == 1) return 'Upload ${formatSize(size)}';
    final mode = concurrency == 1 ? 'sequential' : 'concurrent';
    return '$count $mode uploads of ${formatSize(size)}';
  }

  @override
  String get description {
    if (chunkSize case final chunkSize?) {
      return 'Uploads ${formatSize(size)} as a stream of '
          '${formatSize(chunkSize)} chunks that are only produced as fast as '
          'the client consumes them, like a file upload. Measures streaming '
          'upload throughput. The notes show how far the client read ahead '
          'of the server: a client that buffers the whole body before sending '
          'it has read all of it before the server receives anything.';
    }
    final what = count == 1
        ? 'a ${formatSize(size)} body'
        : '$count ${formatSize(size)} bodies'
              '${concurrency == 1 ? ', one at a time' : ' at the same time'}';
    return 'Uploads $what from memory (`Request.bodyBytes`). Measures upload '
        'throughput, including the cost of copying data from Dart into the '
        'network stack.';
  }

  @override
  Future<void> setUp() async {
    _payload = Uint8List(chunkSize ?? size);
  }

  @override
  Future<void> tearDown() async {
    _payload = null;
  }

  @override
  Future<void> run(ScenarioContext context, TrialRecorder recorder) async {
    final uri = context.uri('/discard');
    final readAhead = <int>[];
    await runConcurrently(count, concurrency, (_) async {
      final payload = _payload!;
      final chunkSize = this.chunkSize;
      if (chunkSize == null) {
        final request = Request('POST', uri)..bodyBytes = payload;
        await timedUpload(context, recorder, request, size);
        return;
      }
      // Ask the server how much of the body it has received at the moment
      // that the client has read all of it.
      final id = uniqueId();
      Future<int?>? receivedWhenRead;
      final request = GeneratedBodyRequest(
        'POST',
        context.uri('/discard', query: {'id': id}),
        chunk: payload,
        chunkCount: size ~/ chunkSize,
        onBodyRead: () => receivedWhenRead = context.server.progress(id),
      );
      await timedUpload(context, recorder, request, size);
      // The server has not seen the request if the client read the whole
      // body before sending the headers.
      final received = await receivedWhenRead ?? 0;
      readAhead.add(size - received);
    });
    if (readAhead.isNotEmpty) {
      final ahead = median(readAhead);
      recorder.notes['read-ahead'] =
          'When the client had read the whole body, the server had received '
          '${formatSize(size - ahead)} of it (the client read '
          '${formatSize(ahead)} ahead of the server).';
    }
  }
}

/// Uploads files using multipart requests.
class MultipartScenario extends Scenario {
  MultipartScenario({required this.count, required this.fileSize});

  /// The number of uploads per trial.
  final int count;

  /// The size of the uploaded file.
  final int fileSize;

  Uint8List? _file;

  static const _fields = {
    'title': 'Sunset',
    'description': 'A photo uploaded by a benchmark',
    'album': 'benchmarks',
    'tags': 'http,dart,benchmark',
    'visibility': 'private',
  };

  @override
  String get id => 'multipart-upload';

  @override
  String get category => Categories.uploads;

  @override
  Metric get metric => Metric.latency;

  @override
  String get title =>
      '$count multipart uploads of a ${formatSize(fileSize)} file';

  @override
  String get description =>
      'Uploads a `MultipartRequest` containing ${_fields.length} form fields '
      'and a ${formatSize(fileSize)} file, $count times, like an app '
      'uploading a photo with its metadata.';

  @override
  Future<void> setUp() async {
    _file = Uint8List(fileSize);
  }

  @override
  Future<void> tearDown() async {
    _file = null;
  }

  @override
  Future<void> run(ScenarioContext context, TrialRecorder recorder) async {
    final uri = context.uri('/discard');
    for (var i = 0; i < count; i++) {
      final request = MultipartRequest('POST', uri)
        ..fields.addAll(_fields)
        ..files.add(
          MultipartFile.fromBytes('photo', _file!, filename: 'photo.jpg'),
        );
      await timedUpload(context, recorder, request, request.contentLength);
    }
  }
}

/// Sends each request with a new client.
class ColdClientScenario extends Scenario {
  ColdClientScenario({required this.count});

  /// The number of requests per trial.
  final int count;

  @override
  String get id => 'cold-client';

  @override
  String get category => Categories.connections;

  @override
  Metric get metric => Metric.latency;

  @override
  String get title => '$count requests, each with a new client';

  @override
  String get description =>
      'Creates a client, sends one GET request for a ${formatSize(_kib)} '
      'response and closes the client, $count times. Measures the cost of '
      'creating a client and a connection, including the TCP and TLS (or '
      'QUIC) handshakes. HTTP/3 clients usually start with HTTP/1.1 or '
      'HTTP/2 because they have not yet discovered that the server supports '
      'HTTP/3.';

  @override
  Future<void> run(ScenarioContext context, TrialRecorder recorder) async {
    final uri = context.uri('/bytes', query: {'size': _kib});
    for (var i = 0; i < count; i++) {
      checkNotCancelled();
      final stopwatch = Stopwatch()..start();
      final client = context.variant.create();
      try {
        final request = Request('GET', uri);
        final response = await client.send(request);
        final ttfb = stopwatch.elapsedMicroseconds;
        var length = 0;
        await for (final chunk in response.stream) {
          length += chunk.length;
        }
        final elapsed = stopwatch.elapsedMicroseconds;
        checkResponse(request, response);
        if (length != _kib) {
          throw BenchmarkException('Expected $_kib bytes, received $length');
        }
        recorder
          ..addSample('ttfb', ttfb)
          ..addSample('latency', elapsed)
          ..operations += 1
          ..bytesReceived += length
          ..addResponse(response);
      } finally {
        try {
          client.close();
        } catch (_) {
          // For example, `CupertinoClient.close` throws if a request is still
          // in progress, which happens after an error. Report that error
          // instead.
        }
      }
    }
    // The runner resets the server's counters before each trial.
    final opened = (await context.server.stats())
        .connectionsFor(context.variant.protocol)
        .opened;
    if (opened < count) {
      recorder.notes['reuse'] =
          'The server accepted only $opened connections for $count clients, '
          'so some connections were shared between clients.';
    }
  }
}

/// Sends and receives many headers.
class HeadersScenario extends Scenario {
  HeadersScenario({
    required this.count,
    this.headerCount = 50,
    this.headerSize = 64,
  });

  /// The number of requests per trial.
  final int count;

  /// The number of custom headers in each request and response.
  final int headerCount;

  /// The length of each header value.
  final int headerSize;

  Map<String, String>? _headers;

  @override
  String get id => 'many-headers';

  @override
  String get category => Categories.payloads;

  @override
  Metric get metric => Metric.latency;

  @override
  String get title =>
      '$count requests with $headerCount request and response headers';

  @override
  String get description =>
      'Sends $count sequential GET requests that each carry $headerCount '
      'custom headers (with ${formatSize(headerSize)} values) and receive '
      '$headerCount custom headers back, like API calls with authentication, '
      'tracing and caching metadata. Measures the cost of encoding and '
      'decoding headers, including HPACK (HTTP/2) and QPACK (HTTP/3) '
      'compression and copying headers between native code and Dart.';

  @override
  Future<void> setUp() async {
    const alphabet =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    _headers = {
      for (var i = 0; i < headerCount; i++)
        'x-bench-request-$i': String.fromCharCodes([
          for (var j = 0, random = math.Random(i); j < headerSize; j++)
            alphabet.codeUnitAt(random.nextInt(alphabet.length)),
        ]),
    };
  }

  @override
  Future<void> tearDown() async {
    _headers = null;
  }

  @override
  Future<void> run(ScenarioContext context, TrialRecorder recorder) async {
    final uri = context.uri(
      '/headers',
      query: {'count': headerCount, 'size': headerSize},
    );
    for (var i = 0; i < count; i++) {
      final request = Request('GET', uri)..headers.addAll(_headers!);
      final result = await timedSend(
        context,
        recorder,
        request,
        keepBody: true,
      );
      final sent = utf8.decode(result.body!);
      if (sent != '$headerCount') {
        throw BenchmarkException(
          'The server received $sent benchmark headers, expected $headerCount',
        );
      }
      final received = result.response.headers.keys
          .where((name) => name.startsWith('x-bench-response-'))
          .length;
      if (received != headerCount) {
        throw BenchmarkException(
          'Received $received benchmark headers, expected $headerCount',
        );
      }
    }
  }
}

/// Fetches and decodes JSON documents in bursts of concurrent requests.
class JsonBurstScenario extends Scenario {
  JsonBurstScenario({
    required this.bursts,
    this.concurrency = 32,
    this.items = 200,
  });

  /// The number of bursts per trial.
  final int bursts;

  /// The number of requests in each burst.
  final int concurrency;

  /// The number of items in each JSON document.
  final int items;

  @override
  String get id => 'json-burst';

  @override
  String get category => Categories.payloads;

  @override
  Metric get metric => Metric.latency;

  @override
  String get title => '$bursts bursts of $concurrency JSON API calls';

  @override
  String get description =>
      'Sends $concurrency concurrent GET requests for JSON documents (each an '
      'array of $items feed items) and decodes the responses with '
      '`jsonDecode`, like an app populating a screen. Each latency sample is '
      'the time taken by a whole burst.';

  @override
  Future<void> run(ScenarioContext context, TrialRecorder recorder) async {
    final uri = context.uri('/json', query: {'items': items});
    Future<void> fetch() async {
      final result = await timedSend(
        context,
        recorder,
        Request('GET', uri),
        keepBody: true,
        record: false,
      );
      final decoded = jsonDecode(utf8.decode(result.body!));
      if (decoded is! List || decoded.length != items) {
        throw BenchmarkException('Unexpected JSON response from $uri');
      }
    }

    for (var i = 0; i < bursts; i++) {
      final stopwatch = Stopwatch()..start();
      await Future.wait([
        for (var j = 0; j < concurrency; j++) fetch(),
      ], eagerError: true);
      recorder.addSample('latency', stopwatch.elapsedMicroseconds);
    }
  }
}

/// Downloads gzip-compressed responses.
class GzipScenario extends Scenario {
  GzipScenario({required this.count, required this.size});

  /// The number of downloads per trial.
  final int count;

  /// The decompressed size of each response.
  final int size;

  @override
  String get id => 'gzip-download';

  @override
  String get category => Categories.payloads;

  @override
  Metric get metric => Metric.throughput;

  @override
  String get title =>
      '$count gzip-compressed downloads of ${formatSize(size)} of text';

  @override
  String get description =>
      'Downloads ${formatSize(size)} of log-like text that the server sends '
      'gzip-compressed, $count times. Throughput is measured in decompressed '
      'bytes. When a client does not decompress responses automatically, the '
      'benchmark decompresses them with `dart:io` (see the notes).';

  @override
  Future<void> run(ScenarioContext context, TrialRecorder recorder) async {
    final uri = context.uri('/text', query: {'size': size, 'gzip': 1});
    for (var i = 0; i < count; i++) {
      checkNotCancelled();
      final request = Request('GET', uri);
      final stopwatch = Stopwatch()..start();
      final response = await context.client.send(request);
      checkResponse(request, response);
      // Count the decompressed bytes as they arrive, decompressing them here
      // if the client did not.
      final counter = _CountingSink();
      bool? isGzip;
      ByteConversionSink? decoder;
      await for (final chunk in response.stream) {
        if (chunk.isEmpty) continue;
        // The text never starts with the first byte of the gzip header.
        isGzip ??= chunk[0] == 0x1f;
        if (isGzip) {
          (decoder ??= gzip.decoder.startChunkedConversion(counter)).add(chunk);
        } else {
          counter.add(chunk);
        }
      }
      decoder?.close();
      if (counter.length != size) {
        throw BenchmarkException(
          'Expected $size bytes, received ${counter.length}',
        );
      }
      recorder
        ..addSample('latency', stopwatch.elapsedMicroseconds)
        ..operations += 1
        ..bytesReceived += counter.length
        ..addResponse(response)
        ..notes['decompression'] = isGzip == true
            ? 'The client returned gzip-encoded bytes, which the benchmark '
                  'decompressed with dart:io.'
            : 'The client decompressed the responses.';
    }
  }
}

/// Counts the bytes added to it.
class _CountingSink implements Sink<List<int>> {
  int length = 0;

  @override
  void add(List<int> data) => length += data.length;

  @override
  void close() {}
}
