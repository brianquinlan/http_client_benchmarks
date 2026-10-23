// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:http_client_benchmarks/http_client_benchmarks.dart';

Future<void> main(List<String> arguments) async {
  final code = await runCli(arguments);
  await Future.wait([stdout.flush(), stderr.flush()]);
  // Exit explicitly: native clients (e.g. NSURLSession) can keep the
  // process alive after they have been closed.
  exit(code);
}
