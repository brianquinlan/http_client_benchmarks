// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:http_client_benchmarks/http_client_benchmarks.dart';
import 'package:test/test.dart';

/// Tests of the support for running the benchmarks on Android devices that do
/// not need a device.
void main() {
  test('goArchitectureForAbi', () {
    expect(goArchitectureForAbi('arm64-v8a'), 'arm64');
    expect(goArchitectureForAbi('armeabi-v7a'), 'arm');
    expect(goArchitectureForAbi('x86_64'), 'amd64');
    expect(goArchitectureForAbi('x86'), '386');
    expect(
      () => goArchitectureForAbi('mips'),
      throwsA(isA<AndroidException>()),
    );
  });

  test('parseAdbDevices only returns devices that are ready', () {
    expect(
      parseAdbDevices(
        '* daemon not running; starting now at tcp:5037\n'
        '* daemon started successfully\n'
        'List of devices attached\n'
        'emulator-5554\tdevice\n'
        '0A1B2C3D\tunauthorized\n'
        '192.168.1.20:5555\toffline\n'
        'R5CT20XYZ\tdevice\n'
        '\n',
      ),
      ['emulator-5554', 'R5CT20XYZ'],
    );
    expect(parseAdbDevices('List of devices attached\n\n'), isEmpty);
  });

  test('AndroidDeviceInfo describes the device', () {
    final info = AndroidDeviceInfo(
      abi: 'arm64-v8a',
      manufacturer: 'Google',
      model: 'Pixel 9',
      release: '16',
      sdk: '36',
      emulator: true,
    );
    expect(info.description, 'Google Pixel 9 (emulator), arm64-v8a');
    expect(info.operatingSystemVersion, 'Android 16 (API 36)');
  });

  test('DeviceRunConfig survives encoding', () {
    final config = DeviceRunConfig(
      server: ServerInfo(
        host: '127.0.0.1',
        controlPort: 1000,
        origins: [
          {
            for (final (i, protocol) in HttpProtocol.values.indexed)
              protocol: 2000 + i,
          },
        ],
        caCertificatePath: '/data/local/tmp/http_client_benchmarks/ca.pem',
        goVersion: 'go1.26.0',
        quicGoVersion: 'v0.64.1',
      ),
      caCertificate: '-----BEGIN CERTIFICATE-----\n…\n',
      configuration: RunConfiguration(
        trials: 3,
        warmup: 1,
        quick: true,
        httpProfiling: false,
      ),
      scenarioIds: ['get-sequential', 'download-large'],
      trialTimeout: const Duration(seconds: 90),
      clients: ['okhttpclient', 'cronetclient'],
      protocols: ['h2'],
      cpu: 'Google Pixel 9, arm64-v8a',
      operatingSystemVersion: 'Android 16 (API 36)',
      gitRevision: 'abc1234',
      verbose: true,
    );

    final decoded = DeviceRunConfig.decode(config.encode());
    expect(decoded.toJson(), config.toJson());
    expect(decoded.server.origins.single[HttpProtocol.http3], 2003);
    expect(decoded.trialTimeout, const Duration(seconds: 90));
  });
}
