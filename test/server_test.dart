// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart';
import 'package:http_client_benchmarks/http_client_benchmarks.dart';
import 'package:test/test.dart';

/// Tests that require Go to build and run the benchmark server.
void main() {
  late BenchmarkServer server;
  late Directory certificates;
  late List<ClientVariant> variants;

  setUpAll(() async {
    certificates = await Directory.systemTemp.createTemp('benchmark_certs');
    server = await BenchmarkServer.start(
      certificateDirectory: certificates.path,
      origins: 2,
    );
    variants = createClientVariants(caCertificate: server.caCertificate);
  });

  tearDownAll(() async {
    await server.close();
    await certificates.delete(recursive: true);
  });

  ClientVariant variant(String id) => variants.firstWhere((v) => v.id == id);

  test('serves each origin and protocol on its own port', () {
    final ports = {
      for (final origin in server.origins) ...origin.values,
      server.controlPort,
    };
    expect(ports, hasLength(server.origins.length * 4 + 1));
    expect(server.caCertificate, isNotEmpty);
    expect(server.goVersion, startsWith('go'));
  });

  for (final (id, protocol) in [
    ('ioclient-h1c', 'HTTP/1.1'),
    ('ioclient-h1', 'HTTP/1.1'),
    ('http2client-h2', 'HTTP/2.0'),
  ]) {
    test('$id reaches the server using $protocol', () async {
      final v = variant(id);
      final client = v.create();
      addTearDown(client.close);
      final response = await client.get(
        server.uri(v.protocol, '/bytes', query: {'size': '1000'}, origin: 1),
      );
      expect(response.statusCode, 200);
      expect(response.bodyBytes, hasLength(1000));
      expect(response.headers['x-protocol'], protocol);
      expect(response.headers['cache-control'], 'no-store');
    });
  }

  test('the HTTP/3 port advertises HTTP/3 over TCP', () async {
    final client = variant('ioclient-h1').create();
    addTearDown(client.close);
    final uri = server.uri(HttpProtocol.http3, '/bytes');
    final response = await client.get(uri);
    expect(response.headers['alt-svc'], 'h3=":${uri.port}"; ma=86400');
  });

  test('counts the connections used by each protocol', () async {
    final v = variant('ioclient-h1c');
    final client = v.create();
    addTearDown(client.close);
    await server.resetStats();
    for (var i = 0; i < 3; i++) {
      await client.get(server.uri(v.protocol, '/bytes'));
    }
    final stats = await server.stats();
    final connections = stats.connectionsFor(HttpProtocol.http1Cleartext);
    expect(connections.used, 1);
    expect(connections.opened, 1);
    expect(stats.requests['HTTP/1.1'], 3);
    expect(stats.connectionsFor(HttpProtocol.http2).used, 0);
  });

  test('discards uploads and reports their size', () async {
    final v = variant('http2client-h2');
    final client = v.create();
    addTearDown(client.close);
    final response = await client.post(
      server.uri(v.protocol, '/discard'),
      body: List.filled(123456, 1),
    );
    expect(response.body, '123456');
  });

  test('reports the progress of requests with an ID', () async {
    final v = variant('ioclient-h1c');
    final client = v.create();
    addTearDown(client.close);
    await server.resetStats();
    expect(await server.progress('download'), isNull);
    await client.get(
      server.uri(
        v.protocol,
        '/bytes',
        query: {'size': '5000', 'id': 'download'},
      ),
    );
    expect(await server.progress('download'), 5000);
    await client.post(
      server.uri(v.protocol, '/discard', query: {'id': 'upload'}),
      body: List.filled(3000, 1),
    );
    expect(await server.progress('upload'), 3000);
    await server.resetStats();
    expect(await server.progress('download'), isNull);
  });

  test('streams server-sent events', () async {
    final v = variant('ioclient-h1c');
    final client = v.create();
    addTearDown(client.close);
    final response = await client.send(
      Request(
        'GET',
        server.uri(
          v.protocol,
          '/sse',
          query: {'events': '3', 'size': '64', 'interval_us': '100'},
        ),
      ),
    );
    final body = await response.stream.bytesToString();
    final events = body.split('\n\n').where((e) => e.isNotEmpty).toList();
    expect(events, hasLength(3));
    expect(events.first, startsWith('data: 0 '));
  });

  test('connect uses a server that is already running', () async {
    // As the Flutter runner app does, using details passed as JSON.
    final connected = BenchmarkServer.connect(
      ServerInfo.fromJson(
        jsonDecode(jsonEncode(server.info.toJson())) as Map<String, Object?>,
      ),
      caCertificate: server.caCertificate,
    );
    final v = variant('ioclient-h1');
    expect(
      connected.uri(v.protocol, '/bytes', origin: 1),
      server.uri(v.protocol, '/bytes', origin: 1),
    );
    final client = v.create();
    addTearDown(client.close);
    await connected.resetStats();
    await client.get(connected.uri(v.protocol, '/bytes'));
    expect((await connected.stats()).requests['HTTP/1.1'], 1);

    // Closing the connection does not stop the server.
    await connected.close();
    expect((await server.stats()).requests['HTTP/1.1'], 1);
  });

  test('builds the server for Android devices', () async {
    final binary = await BenchmarkServer.build(
      os: 'linux',
      architecture: goArchitectureForAbi('arm64-v8a'),
    );
    final header = await File(binary).openRead(0, 4).expand((b) => b).toList();
    expect(header, [0x7f, 0x45, 0x4c, 0x46], reason: 'an ELF executable');
  });
}
