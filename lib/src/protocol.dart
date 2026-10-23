// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// A protocol (and transport) that can be used to reach the benchmark server.
///
/// The benchmark server listens on a different port for each protocol so
/// that clients that negotiate the protocol automatically (e.g. `NSURLSession`)
/// can be steered towards a particular one.
enum HttpProtocol {
  /// HTTP/1.1 without TLS.
  http1Cleartext('h1c', 'HTTP/1.1 (cleartext)', 'HTTP/1.1', secure: false),

  /// HTTP/1.1 over TLS.
  http1('h1', 'HTTP/1.1 (TLS)', 'HTTP/1.1'),

  /// HTTP/2 over TLS.
  http2('h2', 'HTTP/2', 'HTTP/2.0'),

  /// HTTP/3 over QUIC.
  ///
  /// Clients discover HTTP/3 through an "Alt-Svc" header so the first request
  /// to the server uses HTTP/1.1 or HTTP/2.
  http3('h3', 'HTTP/3', 'HTTP/3.0');

  const HttpProtocol(
    this.id,
    this.label,
    this.serverProtocol, {
    this.secure = true,
  });

  /// A short, unique identifier, e.g. "h2".
  final String id;

  /// A human-readable name, e.g. "HTTP/2".
  final String label;

  /// The protocol that the server reports, in the "x-protocol" response
  /// header, when it receives a request using this protocol.
  final String serverProtocol;

  /// Whether the protocol uses TLS.
  final bool secure;

  /// Returns the protocol with the given [id].
  static HttpProtocol fromId(String id) => values.firstWhere(
    (protocol) => protocol.id == id,
    orElse: () => throw ArgumentError.value(id, 'id', 'Unknown protocol'),
  );
}
