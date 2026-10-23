# AGENTS.md

Guidance for AI coding agents working in this repository. People should
start with [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## Overview

`http_client_benchmarks` is a Dart command-line tool (`publish_to: none`, not
a library) that benchmarks `package:http` `Client` implementations
(`IOClient`, `Http2Client` and, on macOS, `CupertinoClient`) against a
purpose-built Go server that speaks HTTP/1.1, HTTP/2 and HTTP/3. The Dart code
builds the server with `go build` whenever it starts it.

## Layout

| Path | Contents |
| --- | --- |
| `bin/benchmark.dart` | Entry point; runs the CLI in `lib/src/cli.dart` (`run`, `compare`, `report` and `list` commands). |
| `lib/src/clients.dart` | The client variants: a client configured to use one protocol. |
| `lib/src/scenario.dart`, `lib/src/scenarios.dart` | The `Scenario` base class and its helpers, and every scenario. |
| `lib/src/runner.dart` | Runs each scenario with each client variant. |
| `lib/src/server.dart` | Builds, starts and queries the Go server. |
| `lib/src/results.dart` | The `results.json` format. |
| `lib/src/stats.dart`, `lib/src/compare.dart` | Statistics, and the comparison of two runs. |
| `lib/src/reporters/` | The console, HTML and Markdown reports. |
| `server/main.go` | The Go server. Its endpoints are documented at the top of the file. |
| `test/` | Dart tests. `server_test.dart` and `runner_test.dart` start the Go server. |

## Commands

```shell
dart pub get
dart format .                  # Format the Dart code.
dart analyze --fatal-infos     # Must report no issues.
dart test                      # About 15 seconds; needs Go.
(cd server && gofmt -l . && go vet ./... && go test ./...)

# End-to-end smoke test of the CLI, about 30 seconds.
dart run bin/benchmark.dart run --quick
```

CI (`.github/workflows/ci.yaml`) runs all of these except the smoke test, on
Linux and macOS.

## Conventions

* Keep the Dart code formatted with `dart format` and free of analysis issues
  (the lints come from `package:dart_flutter_team_lints`), and the Go code
  formatted with `gofmt`.
* Start new source files with the same license header as the existing files.
* Document public APIs with `///` comments.
* When adding or changing scenarios, clients, server endpoints or
  command-line options, update the matching section of `README.md` and, for
  endpoints, the documentation at the top of `server/main.go`.
* Increment `BenchmarkReport.schemaVersion` in `lib/src/results.dart` when
  `results.json` changes in a way that older versions of the tool cannot read.

## Things to avoid

* Do not trust the benchmark's certificate authority
  (`security add-trusted-cert`) or otherwise change the system trust store or
  keychain; leave that to the user. Until the user trusts it,
  `CupertinoClient` can only be benchmarked over cleartext HTTP/1.1 (`h1c`),
  and its other variants being reported as unavailable is expected.
* Do not commit `benchmark_results/`, `pubspec_overrides.yaml` or anything in
  `.dart_tool/`.
* Do not draw conclusions from a single benchmark run: differences of 5–20%
  between identical runs are common. To evaluate a performance change, run
  the affected scenarios before and after the change, back to back and more
  than once, and check the results with `dart run bin/benchmark.dart compare`.
