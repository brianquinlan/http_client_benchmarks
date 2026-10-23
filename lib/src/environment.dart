// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'format.dart';

/// The machine and software used to run the benchmarks.
class Environment {
  Environment({
    required this.operatingSystem,
    required this.operatingSystemVersion,
    required this.dartVersion,
    required this.compilationMode,
    required this.cpu,
    required this.processors,
    this.memoryBytes,
    this.goVersion,
    this.quicGoVersion,
    this.gitRevision,
  });

  factory Environment.fromJson(Map<String, Object?> json) => Environment(
    operatingSystem: json['operatingSystem'] as String,
    operatingSystemVersion: json['operatingSystemVersion'] as String,
    dartVersion: json['dartVersion'] as String,
    compilationMode: json['compilationMode'] as String,
    cpu: json['cpu'] as String,
    processors: json['processors'] as int,
    memoryBytes: json['memoryBytes'] as int?,
    goVersion: json['goVersion'] as String?,
    quicGoVersion: json['quicGoVersion'] as String?,
    gitRevision: json['gitRevision'] as String?,
  );

  /// Describes the current machine.
  ///
  /// [cpu], [operatingSystemVersion] and [gitRevision] replace the values
  /// detected on this machine, e.g. when the benchmarks run on an Android
  /// device, which the machine that controls the device describes better.
  static Future<Environment> capture({
    String? goVersion,
    String? quicGoVersion,
    String? workingDirectory,
    String? cpu,
    String? operatingSystemVersion,
    String? gitRevision,
  }) async => Environment(
    operatingSystem: Platform.operatingSystem,
    operatingSystemVersion:
        operatingSystemVersion ?? Platform.operatingSystemVersion,
    dartVersion: Platform.version.split(' ').first,
    // Flutter's profile mode is also compiled ahead of time.
    compilationMode:
        const bool.fromEnvironment('dart.vm.product') ||
            const bool.fromEnvironment('dart.vm.profile')
        ? 'AOT'
        : 'JIT',
    cpu: cpu ?? await _cpu(),
    processors: Platform.numberOfProcessors,
    memoryBytes: await _memory(),
    goVersion: goVersion,
    quicGoVersion: quicGoVersion,
    gitRevision: gitRevision ?? await _gitRevision(workingDirectory),
  );

  final String operatingSystem;
  final String operatingSystemVersion;
  final String dartVersion;

  /// "JIT" or "AOT".
  final String compilationMode;
  final String cpu;
  final int processors;
  final int? memoryBytes;
  final String? goVersion;
  final String? quicGoVersion;

  /// The git revision of the benchmarked code, with a "-dirty" suffix if
  /// there were uncommitted changes.
  final String? gitRevision;

  /// A one-line summary, e.g. "macos · Apple M3 (8 cores, 16 GiB)".
  String get machine =>
      '$operatingSystem $operatingSystemVersion · $cpu ($processors cores'
      '${memoryBytes == null ? '' : ', ${formatSize(memoryBytes!)}'})';

  /// A one-line summary of the software versions.
  String get software => [
    'Dart $dartVersion ($compilationMode)',
    if (goVersion != null) 'Go ${goVersion!.replaceFirst('go', '')}',
    if (quicGoVersion != null) 'quic-go $quicGoVersion',
    if (gitRevision != null) 'git $gitRevision',
  ].join(' · ');

  Map<String, Object?> toJson() => {
    'operatingSystem': operatingSystem,
    'operatingSystemVersion': operatingSystemVersion,
    'dartVersion': dartVersion,
    'compilationMode': compilationMode,
    'cpu': cpu,
    'processors': processors,
    'memoryBytes': memoryBytes,
    'goVersion': goVersion,
    'quicGoVersion': quicGoVersion,
    'gitRevision': gitRevision,
  };
}

Future<String?> _run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    if (result.exitCode != 0) return null;
    return (result.stdout as String).trim();
  } on ProcessException {
    return null;
  }
}

Future<String> _cpu() async {
  if (Platform.isMacOS) {
    final brand = await _run('sysctl', ['-n', 'machdep.cpu.brand_string']);
    if (brand != null && brand.isNotEmpty) return brand;
  } else if (Platform.isLinux) {
    try {
      for (final line in await File('/proc/cpuinfo').readAsLines()) {
        if (line.startsWith('model name')) return line.split(':').last.trim();
      }
    } on FileSystemException {
      // Fall through.
    }
  }
  return 'unknown CPU';
}

Future<int?> _memory() async {
  if (Platform.isMacOS) {
    return int.tryParse(await _run('sysctl', ['-n', 'hw.memsize']) ?? '');
  } else if (Platform.isLinux || Platform.isAndroid) {
    try {
      for (final line in await File('/proc/meminfo').readAsLines()) {
        if (line.startsWith('MemTotal:')) {
          final kib = int.tryParse(line.split(RegExp(r'\s+'))[1]);
          return kib == null ? null : kib * 1024;
        }
      }
    } on FileSystemException {
      // Fall through.
    }
  }
  return null;
}

Future<String?> _gitRevision(String? workingDirectory) async {
  final revision = await _run('git', [
    'rev-parse',
    '--short',
    'HEAD',
  ], workingDirectory: workingDirectory);
  if (revision == null) return null;
  final status = await _run('git', [
    'status',
    '--porcelain',
    '--untracked-files=no',
  ], workingDirectory: workingDirectory);
  return status == null || status.isEmpty ? revision : '$revision-dirty';
}
