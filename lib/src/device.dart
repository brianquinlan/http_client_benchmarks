// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'cli.dart' show selectVariants;
import 'clients.dart';
import 'environment.dart';
import 'results.dart';
import 'runner.dart';
import 'scenarios.dart';
import 'server.dart';

/// Everything that a device, such as an Android phone, needs in order to run
/// the benchmarks against a server that the controlling machine started on
/// the device.
///
/// The controlling machine [encode]s the configuration and passes it to the
/// Flutter runner app (see `flutter_runner`), which decodes it and calls
/// [runOnDevice].
class DeviceRunConfig {
  DeviceRunConfig({
    required this.server,
    required this.caCertificate,
    required this.configuration,
    required this.scenarioIds,
    required this.trialTimeout,
    this.clients = const [],
    this.protocols = const [],
    this.cpu,
    this.operatingSystemVersion,
    this.gitRevision,
    this.verbose = false,
  });

  factory DeviceRunConfig.fromJson(Map<String, Object?> json) =>
      DeviceRunConfig(
        server: ServerInfo.fromJson(json['server'] as Map<String, Object?>),
        caCertificate: json['caCertificate'] as String,
        configuration: RunConfiguration.fromJson(
          json['configuration'] as Map<String, Object?>,
        ),
        scenarioIds: (json['scenarios'] as List<Object?>).cast<String>(),
        trialTimeout: Duration(seconds: json['trialTimeoutSeconds'] as int),
        clients: (json['clients'] as List<Object?>).cast<String>(),
        protocols: (json['protocols'] as List<Object?>).cast<String>(),
        cpu: json['cpu'] as String?,
        operatingSystemVersion: json['operatingSystemVersion'] as String?,
        gitRevision: json['gitRevision'] as String?,
        verbose: json['verbose'] as bool,
      );

  /// Decodes a configuration encoded by [encode].
  factory DeviceRunConfig.decode(String encoded) => DeviceRunConfig.fromJson(
    jsonDecode(utf8.decode(base64Url.decode(encoded))) as Map<String, Object?>,
  );

  /// The server, which runs on the device.
  final ServerInfo server;

  /// The PEM-encoded certificate of the CA that signed the server's
  /// certificate.
  final String caCertificate;

  final RunConfiguration configuration;

  /// The IDs of the scenarios to run.
  final List<String> scenarioIds;

  /// How long a trial may take before it is abandoned.
  final Duration trialTimeout;

  /// The lowercase names of the clients to benchmark, or empty for every
  /// client.
  final List<String> clients;

  /// The IDs of the protocols to use, or empty for every protocol.
  final List<String> protocols;

  /// Replaces the description of the device's processor detected on the
  /// device.
  final String? cpu;

  /// Replaces the operating system version detected on the device.
  final String? operatingSystemVersion;

  /// The git revision of the benchmarks, which the device cannot determine.
  final String? gitRevision;

  /// Whether to log unexpected, asynchronous errors.
  final bool verbose;

  Map<String, Object?> toJson() => {
    'server': server.toJson(),
    'caCertificate': caCertificate,
    'configuration': configuration.toJson(),
    'scenarios': scenarioIds,
    'trialTimeoutSeconds': trialTimeout.inSeconds,
    'clients': clients,
    'protocols': protocols,
    'cpu': cpu,
    'operatingSystemVersion': operatingSystemVersion,
    'gitRevision': gitRevision,
    'verbose': verbose,
  };

  /// Encodes this configuration as a string that can be passed to the app
  /// with `--dart-define`.
  String encode() => base64Url.encode(utf8.encode(jsonEncode(toJson())));
}

/// Runs the benchmarks described by [config] on this device, against the
/// server that is already running on it.
///
/// [createPlatformVariants] returns the client variants that this library
/// cannot create, such as Flutter plugins (see [androidClientNames]).
Future<BenchmarkReport> runOnDevice(
  DeviceRunConfig config, {
  List<ClientVariant> Function(BenchmarkServer server)? createPlatformVariants,
  RunnerListener? listener,
}) async {
  final server = BenchmarkServer.connect(
    config.server,
    caCertificate: utf8.encode(config.caCertificate),
  );
  try {
    // `HttpClientRequestProfile.profilingEnabled` is backed by this setting.
    HttpClient.enableTimelineLogging = config.configuration.httpProfiling;
    final scenarioIds = config.scenarioIds.toSet();
    return await BenchmarkRunner(
      server: server,
      environment: await Environment.capture(
        goVersion: server.goVersion,
        quicGoVersion: server.quicGoVersion,
        cpu: config.cpu,
        operatingSystemVersion: config.operatingSystemVersion,
        gitRevision: config.gitRevision,
      ),
      variants: selectVariants(
        [
          ...createClientVariants(caCertificate: server.caCertificate),
          ...?createPlatformVariants?.call(server),
        ],
        clients: config.clients,
        protocols: config.protocols,
      ),
      scenarios: [
        for (final scenario in createScenarios(
          quick: config.configuration.quick,
        ))
          if (scenarioIds.contains(scenario.id)) scenario,
      ],
      configuration: config.configuration,
      trialTimeout: config.trialTimeout,
      listener: listener,
      verbose: config.verbose,
    ).run();
  } finally {
    await server.close();
  }
}
