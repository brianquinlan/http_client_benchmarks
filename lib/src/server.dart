// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'protocol.dart';

/// Thrown when the benchmark server cannot be built or started.
class BenchmarkServerException implements Exception {
  BenchmarkServerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Connection counters for the listeners that serve one protocol.
class ConnectionStats {
  const ConnectionStats({
    required this.opened,
    required this.used,
    required this.open,
    required this.peakOpen,
  });

  factory ConnectionStats.fromJson(Map<String, Object?> json) =>
      ConnectionStats(
        opened: json['opened'] as int,
        used: json['used'] as int,
        open: json['open'] as int,
        peakOpen: json['peakOpen'] as int,
      );

  static const zero = ConnectionStats(opened: 0, used: 0, open: 0, peakOpen: 0);

  /// The number of connections accepted since the counters were reset.
  final int opened;

  /// The number of distinct connections that served at least one request
  /// since the counters were reset.
  final int used;

  /// The number of connections that are currently open.
  final int open;

  /// The maximum number of simultaneously open connections since the
  /// counters were reset.
  final int peakOpen;

  /// Combines the counters of two listeners.
  ///
  /// The combined [peakOpen] is an upper bound, because the listeners may
  /// have reached their peaks at different times.
  ConnectionStats operator +(ConnectionStats other) => ConnectionStats(
    opened: opened + other.opened,
    used: used + other.used,
    open: open + other.open,
    peakOpen: peakOpen + other.peakOpen,
  );
}

/// A snapshot of the benchmark server's counters.
class ServerStats {
  ServerStats({required this.connections, required this.requests});

  factory ServerStats.fromJson(Map<String, Object?> json) => ServerStats(
    connections: {
      for (final MapEntry(:key, :value)
          in (json['connections'] as Map<String, Object?>).entries)
        key: ConnectionStats.fromJson(value as Map<String, Object?>),
    },
    requests: {
      for (final MapEntry(:key, :value)
          in (json['requests'] as Map<String, Object?>).entries)
        key: value as int,
    },
  );

  /// Connection counters keyed by listener kind ("h1c", "h1", "h2", "h3tcp"
  /// and "h3quic").
  final Map<String, ConnectionStats> connections;

  /// The number of requests received, keyed by protocol (e.g. "HTTP/2.0").
  final Map<String, int> requests;

  /// The connection counters of the listeners that serve [protocol].
  ///
  /// For HTTP/3, this includes the TCP connections used to discover HTTP/3
  /// (and by clients that fall back to TCP).
  ConnectionStats connectionsFor(HttpProtocol protocol) => switch (protocol) {
    HttpProtocol.http1Cleartext => _kind('h1c'),
    HttpProtocol.http1 => _kind('h1'),
    HttpProtocol.http2 => _kind('h2'),
    HttpProtocol.http3 => _kind('h3quic') + _kind('h3tcp'),
  };

  ConnectionStats _kind(String kind) =>
      connections[kind] ?? ConnectionStats.zero;

  /// The number of connections that are open, across all listeners.
  int get openConnections =>
      connections.values.fold(0, (total, stats) => total + stats.open);
}

/// The Go benchmark server (see `server/main.go`), running in a child
/// process.
class BenchmarkServer {
  BenchmarkServer._({
    required Process process,
    required this.host,
    required this.controlPort,
    required this.origins,
    required this.caCertificatePath,
    required this.caCertificate,
    required this.goVersion,
    required this.quicGoVersion,
  }) : _process = process;

  final Process _process;

  // The control connection must not go through a proxy configured in the
  // environment (e.g. `http_proxy`).
  final HttpClient _control = HttpClient()..findProxy = (_) => 'DIRECT';

  /// The address that the server listens on.
  final String host;

  /// The port that serves the server's counters.
  final int controlPort;

  /// The ports for each protocol, for each origin.
  final List<Map<HttpProtocol, int>> origins;

  /// The path of the PEM-encoded certificate of the CA that signed the
  /// server's certificate.
  final String caCertificatePath;

  /// The PEM-encoded certificate of the CA that signed the server's
  /// certificate.
  final Uint8List caCertificate;

  /// The version of Go used to build the server.
  final String goVersion;

  /// The version of the `quic-go` module used to build the server.
  final String quicGoVersion;

  /// Returns the root directory of this package.
  static Future<String> packageDirectory() async {
    final libraryUri = await Isolate.resolvePackageUri(
      Uri.parse('package:http_client_benchmarks/http_client_benchmarks.dart'),
    );
    if (libraryUri == null || !libraryUri.isScheme('file')) {
      throw BenchmarkServerException(
        'Unable to locate the http_client_benchmarks package. Run the '
        'benchmarks with "dart run" or pass the package directory explicitly.',
      );
    }
    return p.dirname(p.dirname(libraryUri.toFilePath()));
  }

  /// Builds (if necessary) and starts the benchmark server.
  ///
  /// The certificate authority used by the server is created in
  /// [certificateDirectory] (by default `.dart_tool/http_client_benchmarks/
  /// certs` inside this package) and reused across runs.
  static Future<BenchmarkServer> start({
    String? packageDirectory,
    String? certificateDirectory,
    int origins = 4,
    bool verbose = false,
  }) async {
    packageDirectory ??= await BenchmarkServer.packageDirectory();
    final toolDirectory = p.join(
      packageDirectory,
      '.dart_tool',
      'http_client_benchmarks',
    );
    final binary = p.join(
      toolDirectory,
      Platform.isWindows ? 'server.exe' : 'server',
    );
    await _build(p.join(packageDirectory, 'server'), binary);

    final process = await Process.start(binary, [
      '-cert-dir',
      certificateDirectory ?? p.join(toolDirectory, 'certs'),
      '-origins',
      '$origins',
      if (verbose) '-verbose',
    ]);

    final ready = Completer<Map<String, Object?>>();
    final stderrTail = <String>[];
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (verbose) stderr.writeln('[server] $line');
          stderrTail.add(line);
          if (stderrTail.length > 20) stderrTail.removeAt(0);
        });
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (ready.isCompleted) {
            if (verbose) stderr.writeln('[server] $line');
            return;
          }
          try {
            ready.complete(jsonDecode(line) as Map<String, Object?>);
          } on FormatException {
            ready.completeError(
              BenchmarkServerException('Unexpected server output: $line'),
            );
          }
        });
    unawaited(
      process.exitCode.then((exitCode) {
        if (!ready.isCompleted) {
          ready.completeError(
            BenchmarkServerException(
              'The benchmark server exited with code $exitCode:\n'
              '${stderrTail.join('\n')}',
            ),
          );
        }
      }),
    );

    try {
      final Map<String, Object?> info;
      try {
        info = await ready.future.timeout(const Duration(seconds: 30));
      } on TimeoutException {
        throw BenchmarkServerException(
          'Timed out waiting for the benchmark server to start.',
        );
      }

      final caCertificatePath = info['caCertificate'] as String;
      return BenchmarkServer._(
        process: process,
        host: info['host'] as String,
        controlPort: info['controlPort'] as int,
        origins: [
          for (final origin in info['origins'] as List<Object?>)
            {
              for (final protocol in HttpProtocol.values)
                protocol: (origin as Map<String, Object?>)[protocol.id] as int,
            },
        ],
        caCertificatePath: caCertificatePath,
        caCertificate: await File(caCertificatePath).readAsBytes(),
        goVersion: info['goVersion'] as String,
        quicGoVersion: info['quicGoVersion'] as String,
      );
    } catch (_) {
      process.kill();
      rethrow;
    }
  }

  static Future<void> _build(String serverDirectory, String binary) async {
    final ProcessResult result;
    try {
      result = await Process.run('go', [
        'build',
        '-o',
        binary,
        '.',
      ], workingDirectory: serverDirectory);
    } on ProcessException catch (e) {
      throw BenchmarkServerException(
        'Unable to run "go" (${e.message}). Go 1.26 or later is required to '
        'build the benchmark server; see https://go.dev/dl/.',
      );
    }
    if (result.exitCode != 0) {
      throw BenchmarkServerException(
        'Failed to build the benchmark server in $serverDirectory:\n'
        '${result.stderr}',
      );
    }
  }

  /// The URL of [path] on the server, using [protocol].
  Uri uri(
    HttpProtocol protocol,
    String path, {
    Map<String, String>? query,
    int origin = 0,
  }) => Uri(
    scheme: protocol.secure ? 'https' : 'http',
    host: host,
    port: origins[origin][protocol],
    path: path,
    queryParameters: query == null || query.isEmpty ? null : query,
  );

  /// Sends a request to the control port, returning the status code and body.
  Future<(int, String)> _controlRequest(String method, String path) async {
    Future<(int, String)> send() async {
      final request = await _control.open(method, host, controlPort, path);
      final response = await request.close();
      return (
        response.statusCode,
        await response.transform(utf8.decoder).join(),
      );
    }

    try {
      return await send().timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw BenchmarkServerException(
        'The benchmark server did not respond to $method $path.',
      );
    }
  }

  /// Returns a snapshot of the server's counters.
  Future<ServerStats> stats() async {
    final (_, body) = await _controlRequest('GET', '/stats');
    return ServerStats.fromJson(jsonDecode(body) as Map<String, Object?>);
  }

  /// Resets the server's counters and forgets all progress IDs.
  Future<void> resetStats() => _controlRequest('POST', '/stats/reset');

  /// Returns the number of body bytes that the server has written (for
  /// `/bytes`) or read (for `/discard`) for the request with the query
  /// parameter `id=[id]`, or `null` if it has not seen that request since
  /// the counters were last reset.
  Future<int?> progress(String id) async {
    final (status, body) = await _controlRequest(
      'GET',
      Uri(path: '/progress', queryParameters: {'id': id}).toString(),
    );
    if (status == HttpStatus.notFound) return null;
    return (jsonDecode(body) as Map<String, Object?>)['bytes'] as int;
  }

  /// Stops the server.
  Future<void> close() async {
    _control.close(force: true);
    // The server exits when its stdin is closed.
    try {
      await _process.stdin.close();
    } on IOException {
      // The server has already exited.
    }
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}
