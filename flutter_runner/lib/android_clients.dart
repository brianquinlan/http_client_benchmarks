// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:cronet_http/cronet_http.dart';
import 'package:http_client_benchmarks/http_client_benchmarks.dart';
import 'package:ok_http/ok_http.dart';

/// Returns the variants of the clients that can only be benchmarked on
/// Android (see [androidClientNames]).
///
/// The clients use their default configurations, except that the HTTP/3
/// variant of `CronetClient` enables QUIC and tells Cronet which ports of
/// [server] serve HTTP/3, so that it doesn't have to discover them.
///
/// The connections to [server] are verified using the benchmark CA, which the
/// app's network security configuration
/// (`android/app/src/main/res/xml/network_security_config.xml`) trusts for
/// connections to the server.
///
/// The clients are skipped in the scenarios that would exhaust the app's
/// memory (and so end the run).
List<ClientVariant> createAndroidClientVariants(BenchmarkServer server) {
  const okHttpSkipped = {
    'download-cancel':
        'OkHttpClient keeps receiving responses after their streams are '
        'cancelled, which slows down the runs that follow and exhausts the '
        "app's memory",
  };
  final cronetSkipped = {
    for (final scenario in createScenarios())
      if (scenario.category == Categories.uploads)
        scenario.id:
            'CronetClient keeps request bodies in memory after the requests '
            "complete, which exhausts the app's memory",
  };
  return [
    for (final protocol in [
      HttpProtocol.http1Cleartext,
      HttpProtocol.http1,
      HttpProtocol.http2,
    ])
      ClientVariant(
        client: 'OkHttpClient',
        protocol: protocol,
        factory: OkHttpClient.new,
        skippedScenarios: okHttpSkipped,
      ),
    for (final protocol in [
      HttpProtocol.http1Cleartext,
      HttpProtocol.http1,
      HttpProtocol.http2,
    ])
      ClientVariant(
        client: 'CronetClient',
        protocol: protocol,
        factory: CronetClient.defaultCronetEngine,
        skippedScenarios: cronetSkipped,
      ),
    ClientVariant(
      client: 'CronetClient',
      protocol: HttpProtocol.http3,
      factory: () => CronetClient.fromCronetEngine(
        CronetEngine.build(
          enableQuic: true,
          quicHints: [
            for (final origin in server.origins)
              (
                server.host,
                origin[HttpProtocol.http3]!,
                origin[HttpProtocol.http3]!,
              ),
          ],
        ),
        closeEngine: true,
      ),
      skippedScenarios: cronetSkipped,
    ),
  ];
}
