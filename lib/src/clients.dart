// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'dart:typed_data';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart';
import 'package:http/io_client.dart';
import 'package:http2/client.dart';

import 'protocol.dart';

/// The names of the [Client] implementations that can be benchmarked.
const clientNames = ['IOClient', 'Http2Client', 'CupertinoClient'];

/// A [Client] implementation, configured to use a particular [HttpProtocol].
class ClientVariant {
  ClientVariant({
    required this.client,
    required this.protocol,
    required Client Function() factory,
  }) : _factory = factory;

  /// The name of the [Client] implementation, e.g. "IOClient".
  final String client;

  /// The protocol that the client is expected to use.
  final HttpProtocol protocol;

  final Client Function() _factory;

  /// A unique identifier, e.g. "ioclient-h1".
  String get id => '${client.toLowerCase()}-${protocol.id}';

  /// A short human-readable name, e.g. "IOClient h1".
  String get name => '$client ${protocol.id}';

  /// Creates a new [Client].
  Client create() => _factory();
}

/// Returns the client variants that can be run on this platform.
///
/// TLS connections are verified using [caCertificate], the PEM-encoded
/// certificate of the benchmark server's certificate authority. Clients that
/// use the platform's certificate store (e.g. `CupertinoClient`) can only
/// connect using TLS if that certificate authority is trusted by the platform.
List<ClientVariant> createClientVariants({Uint8List? caCertificate}) {
  // Created once and shared by every client, as applications typically share
  // `SecurityContext.defaultContext`, so that creating a client does not
  // include parsing the certificate. (dart:io does not offer TLS session
  // resumption, so sharing the context should not make handshakes cheaper.)
  SecurityContext? sharedContext;
  SecurityContext securityContext() {
    if (caCertificate == null) {
      throw StateError('A CA certificate is required for TLS connections');
    }
    return sharedContext ??= SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(caCertificate);
  }

  // Bypass any proxy configured in the environment (e.g. `http_proxy`); the
  // benchmark server is always reachable directly.
  HttpClient httpClient([SecurityContext? context]) =>
      HttpClient(context: context)..findProxy = (_) => 'DIRECT';

  return [
    ClientVariant(
      client: 'IOClient',
      protocol: HttpProtocol.http1Cleartext,
      factory: () => IOClient(httpClient()),
    ),
    ClientVariant(
      client: 'IOClient',
      protocol: HttpProtocol.http1,
      factory: () => IOClient(httpClient(securityContext())),
    ),
    ClientVariant(
      client: 'Http2Client',
      protocol: HttpProtocol.http2,
      // ignore: experimental_member_use
      factory: () => Http2Client(context: securityContext()),
    ),
    if (Platform.isMacOS || Platform.isIOS)
      for (final protocol in HttpProtocol.values)
        ClientVariant(
          client: 'CupertinoClient',
          protocol: protocol,
          factory: () => CupertinoClient.fromSessionConfiguration(
            URLSessionConfiguration.ephemeralSessionConfiguration(),
          ),
        ),
  ];
}
