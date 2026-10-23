// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'device.dart';
import 'results.dart';
import 'server.dart';

/// Thrown when the benchmarks cannot run on an Android device.
class AndroidException implements Exception {
  AndroidException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Returns the Go architecture (`GOARCH`) of executables for the Android
/// [abi], e.g. "arm64" for "arm64-v8a".
String goArchitectureForAbi(String abi) => switch (abi) {
  'arm64-v8a' => 'arm64',
  'armeabi-v7a' => 'arm',
  'x86_64' => 'amd64',
  'x86' => '386',
  _ => throw AndroidException('Unsupported Android ABI: $abi'),
};

/// Returns the serial numbers of the devices listed by `adb devices` that
/// are ready to use (rather than, e.g., offline or unauthorized).
List<String> parseAdbDevices(String output) => [
  for (final line in LineSplitter.split(output))
    if (line.trim().split(RegExp(r'\s+')) case [final serial, 'device']) serial,
];

/// A description of an Android device.
class AndroidDeviceInfo {
  AndroidDeviceInfo({
    required this.abi,
    required this.manufacturer,
    required this.model,
    required this.release,
    required this.sdk,
    required this.emulator,
  });

  /// The device's primary ABI, e.g. "arm64-v8a".
  final String abi;
  final String manufacturer;
  final String model;

  /// The Android version, e.g. "16".
  final String release;

  /// The API level, e.g. "36".
  final String sdk;
  final bool emulator;

  /// The device and its ABI, e.g. "Google Pixel 9 (emulator), arm64-v8a".
  String get description =>
      '$manufacturer $model${emulator ? ' (emulator)' : ''}, $abi';

  /// The Android version, e.g. "Android 16 (API 36)".
  String get operatingSystemVersion => 'Android $release (API $sdk)';
}

/// An Android device or emulator, controlled using `adb`.
class AndroidDevice {
  AndroidDevice(this.serial);

  /// The device's serial number, as listed by `adb devices`.
  final String serial;

  /// The directory on the device to which the server and CA are copied.
  static const remoteDirectory = '/data/local/tmp/http_client_benchmarks';

  /// The directory that contains the CA for benchmarks on Android devices
  /// unless another one is given.
  ///
  /// It is not the CA used on this machine because, unlike that CA on macOS,
  /// it can't be restricted to loopback IP addresses (see
  /// `BenchmarkServer.start`).
  static String defaultCertificateDirectory(String packageDirectory) => p.join(
    p.dirname(BenchmarkServer.defaultCertificateDirectory(packageDirectory)),
    'android-certs',
  );

  /// Returns the serial numbers of the connected devices that are ready to
  /// use.
  static Future<List<String>> connected() async =>
      parseAdbDevices(await _adb(['devices']));

  /// Runs `adb` with [arguments] for this device, returning its output.
  Future<String> adb(List<String> arguments) =>
      _adb(['-s', serial, ...arguments]);

  /// Returns the value of the system property [name].
  Future<String> property(String name) async =>
      (await adb(['shell', 'getprop', name])).trim();

  /// Describes the device.
  Future<AndroidDeviceInfo> describe() async => AndroidDeviceInfo(
    abi: await property('ro.product.cpu.abi'),
    manufacturer: await property('ro.product.manufacturer'),
    model: await property('ro.product.model'),
    release: await property('ro.build.version.release'),
    sdk: await property('ro.build.version.sdk'),
    emulator:
        serial.startsWith('emulator-') ||
        await property('ro.boot.qemu') == '1' ||
        await property('ro.kernel.qemu') == '1',
  );

  static Future<String> _adb(List<String> arguments) async {
    final ProcessResult result;
    try {
      result = await Process.run('adb', arguments);
    } on ProcessException catch (e) {
      throw AndroidException(
        'Unable to run "adb" (${e.message}). The Android SDK platform tools '
        'are required to benchmark on Android; see '
        'https://developer.android.com/tools/releases/platform-tools.',
      );
    }
    if (result.exitCode != 0) {
      throw AndroidException(
        '"adb ${arguments.join(' ')}" failed with exit code '
        '${result.exitCode}: ${result.stderr}${result.stdout}',
      );
    }
    return result.stdout as String;
  }
}

/// A benchmark server running on an Android device.
class AndroidServer {
  AndroidServer._(this.device, this._process, this.info);

  final AndroidDevice device;
  final Process _process;

  /// The details that the server reported when it started.
  final ServerInfo info;

  /// Builds the server for the device's [abi], copies it and the benchmark CA
  /// from [certificateDirectory] to [device], and starts it.
  ///
  /// The CA's private key is deleted from the device once the server has
  /// started.
  static Future<AndroidServer> start(
    AndroidDevice device, {
    required String abi,
    required String packageDirectory,
    required String certificateDirectory,
    int origins = 4,
    bool verbose = false,
  }) async {
    final binary = await BenchmarkServer.build(
      packageDirectory: packageDirectory,
      os: 'linux',
      architecture: goArchitectureForAbi(abi),
    );
    const directory = AndroidDevice.remoteDirectory;
    await _stopServers(device);
    await device.adb(['shell', 'mkdir', '-p', '$directory/certs']);
    await device.adb(['push', binary, '$directory/server']);
    await device.adb([
      'push',
      p.join(certificateDirectory, 'ca.pem'),
      p.join(certificateDirectory, 'ca-key.pem'),
      '$directory/certs/',
    ]);
    await device.adb(['shell', 'chmod', '755', '$directory/server']);

    // The server can't tell when `adb` exits, so it is stopped explicitly.
    final process = await Process.start('adb', [
      '-s',
      device.serial,
      'shell',
      '$directory/server',
      '-cert-dir',
      '$directory/certs',
      '-origins',
      '$origins',
      // `dart:io` verifies certificates with BoringSSL on Android (see
      // `BenchmarkServer.start`).
      '-ip-constraints=false',
      '-exit-on-stdin-eof=false',
      if (verbose) '-verbose',
    ]);
    try {
      final info = await ServerInfo.waitFor(process, verbose: verbose);
      await device.adb(['shell', 'rm', '-f', '$directory/certs/ca-key.pem']);
      final expected = await File(
        p.join(certificateDirectory, 'ca.pem'),
      ).readAsString();
      final actual = await device.adb([
        'exec-out',
        'cat',
        info.caCertificatePath,
      ]);
      if (actual != expected) {
        throw AndroidException(
          'The server on the device is not using the benchmark CA in '
          '$certificateDirectory.',
        );
      }
      return AndroidServer._(device, process, info);
    } catch (_) {
      await _stopServers(device);
      process.kill();
      rethrow;
    }
  }

  static Future<void> _stopServers(AndroidDevice device) async {
    try {
      await device.adb([
        'shell',
        'pkill',
        '-f',
        '${AndroidDevice.remoteDirectory}/server',
      ]);
    } on AndroidException {
      // No server was running.
    }
  }

  /// Stops the server.
  Future<void> close() async {
    await _stopServers(device);
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
  }
}

/// Runs the benchmarks described by [config] in the Flutter runner app
/// (`flutter_runner`) on [device], and returns the results.
///
/// The app is built in profile mode and run with `flutter drive`. If
/// [embeddedCronet] is true then the app uses Cronet from
/// `org.chromium.net:cronet-embedded` rather than from Google Play Services.
Future<BenchmarkReport> runFlutterRunner({
  required String packageDirectory,
  required AndroidDevice device,
  required DeviceRunConfig config,
  bool embeddedCronet = false,
}) async {
  final runnerDirectory = p.join(packageDirectory, 'flutter_runner');
  // The app's network security configuration trusts this CA (only) for
  // connections to the server.
  final caFile = File(
    p.join(
      runnerDirectory,
      'android',
      'app',
      'src',
      'main',
      'res',
      'raw',
      'benchmark_ca.pem',
    ),
  );
  // Only write the CA when it has changed, so that the app isn't rebuilt
  // unnecessarily.
  if (!caFile.existsSync() ||
      caFile.readAsStringSync() != config.caCertificate) {
    await caFile.parent.create(recursive: true);
    await caFile.writeAsString(config.caCertificate);
  }

  final temporary = await Directory.systemTemp.createTemp(
    'http_client_benchmarks',
  );
  try {
    final resultsPath = p.join(temporary.path, 'results.json');
    final Process process;
    try {
      process = await Process.start(
        'flutter',
        [
          'drive',
          '--profile',
          '--device-id',
          device.serial,
          '--target',
          'integration_test/benchmark_test.dart',
          '--driver',
          'test_driver/integration_test.dart',
          '--dart-define',
          'BENCHMARK_CONFIG=${config.encode()}',
          if (embeddedCronet) ...['--dart-define', 'cronetHttpNoPlay=true'],
        ],
        workingDirectory: runnerDirectory,
        // Read by test_driver/integration_test.dart.
        environment: {'BENCHMARK_RESULTS': resultsPath},
        mode: ProcessStartMode.inheritStdio,
      );
    } on ProcessException catch (e) {
      throw AndroidException(
        'Unable to run "flutter" (${e.message}). Flutter is required to '
        'benchmark on Android; see https://docs.flutter.dev/get-started.',
      );
    }
    final exitCode = await process.exitCode;
    final results = File(resultsPath);
    if (!results.existsSync()) {
      throw AndroidException(
        'The benchmarks did not complete on the device ("flutter drive" '
        'exited with code $exitCode).',
      );
    }
    return BenchmarkReport.fromJson(
      jsonDecode(await results.readAsString()) as Map<String, Object?>,
    );
  } finally {
    await temporary.delete(recursive: true);
  }
}
