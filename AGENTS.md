# AGENTS.md

Guidance for AI coding agents working in this repository. People should
start with [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## Overview

`http_client_benchmarks` is a Dart command-line tool (`publish_to: none`, not
a library) that benchmarks `package:http` `Client` implementations against a
purpose-built Go server that speaks HTTP/1.1, HTTP/2 and HTTP/3. The Dart code
builds the server with `go build` whenever it starts it.

The benchmarks run in the Dart VM (`IOClient`, `Http2Client`, `CurlClient`
and, on macOS, `CupertinoClient`), or on an Android device (`IOClient`,
`Http2Client`, `OkHttpClient` and `CronetClient`). On Android, the tool
cross-compiles the server, starts it on the device with `adb`, and runs the
benchmarks in a Flutter app (`flutter_runner/`) with `flutter drive`.

## Layout

| Path | Contents |
| --- | --- |
| `bin/benchmark.dart` | Entry point; runs the CLI in `lib/src/cli.dart` (`run`, `compare`, `report` and `list` commands). |
| `lib/src/clients.dart` | The client variants: a client configured to use one protocol. |
| `lib/src/scenario.dart`, `lib/src/scenarios.dart` | The `Scenario` base class and its helpers, and every scenario. |
| `lib/src/runner.dart` | Runs each scenario with each client variant. |
| `lib/src/server.dart` | Builds, starts and queries the Go server. |
| `lib/src/android.dart` | Runs on the computer for `run --device`: controls the device with `adb`, starts the server on it and runs `flutter_runner`. |
| `lib/src/device.dart` | Runs on the device: the configuration passed to `flutter_runner`, and `runOnDevice`. |
| `lib/src/results.dart` | The `results.json` format. |
| `lib/src/stats.dart`, `lib/src/compare.dart` | Statistics, and the comparison of two runs. |
| `lib/src/reporters/` | The console, HTML and Markdown reports. |
| `server/main.go` | The Go server. Its endpoints are documented at the top of the file. |
| `test/` | Dart tests. `server_test.dart` and `runner_test.dart` start the Go server. |
| `flutter_runner/` | The Flutter app for Android: `integration_test/benchmark_test.dart` runs on the device, `test_driver/integration_test.dart` receives the results, and `lib/android_clients.dart` defines the Android-only clients. |

## Commands

```shell
dart pub get
dart format .                  # Format the Dart code (including flutter_runner).
dart analyze --fatal-infos     # Must report no issues.
dart test                      # About 15 seconds; needs Go.
(cd server && gofmt -l . && go vet ./... && go test ./...)
(cd flutter_runner && flutter analyze)

# End-to-end smoke test of the CLI, about 30 seconds.
dart run bin/benchmark.dart run --quick

# End-to-end smoke test on Android; needs Flutter and a device or emulator
# (see `adb devices`). The first run builds the app, which takes minutes.
dart run bin/benchmark.dart run --device emulator-5554 --quick -s get-sequential
```

CI (`.github/workflows/ci.yaml`) runs all of these except the smoke tests.

## Conventions

* Keep the Dart code formatted with `dart format` and free of analysis issues
  (the lints come from `package:dart_flutter_team_lints`), and the Go code
  formatted with `gofmt`.
* Start new source files with the same license header as the existing files.
* Document public APIs with `///` comments.
* When adding or changing scenarios, clients, server endpoints or
  command-line options, update the matching section of `README.md` and, for
  endpoints, the documentation at the top of `server/main.go`.
* Clients that are Flutter plugins (and so can't be imported by the
  command-line tool) belong in `flutter_runner/lib/android_clients.dart`,
  with their names in `androidClientNames` (`lib/src/clients.dart`).
* Increment `BenchmarkReport.schemaVersion` in `lib/src/results.dart` when
  `results.json` changes in a way that older versions of the tool cannot read.

## Things to avoid

* Do not add the benchmark's certificate authority to the system trust store
  or keychain (e.g. with `security add-trusted-cert`); the clients are
  configured to trust it themselves (`CupertinoClient` with `onChallenge`).
* Do not restrict the CA to loopback IP addresses (the server's
  `-ip-constraints` flag) where `dart:io` verifies certificates with
  BoringSSL (everywhere except Apple platforms): BoringSSL then rejects the
  server's certificate.
* Do not commit `benchmark_results/`, `pubspec_overrides.yaml`, anything in
  `.dart_tool/`, or `flutter_runner/android/app/src/main/res/raw/benchmark_ca.pem`
  (which the tool writes).
* Do not draw conclusions from a single benchmark run: differences of 5–20%
  between identical runs are common. To evaluate a performance change, run
  the affected scenarios before and after the change, back to back and more
  than once, and check the results with `dart run bin/benchmark.dart compare`.
