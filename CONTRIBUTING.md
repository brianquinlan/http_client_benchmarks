# Contributing

Bug reports, new scenarios, support for more clients and fixes are all
welcome.

## Reporting problems

Please [open an issue](https://github.com/brianquinlan/http_client_benchmarks/issues).
If a client performs unexpectedly, attach the `report.md` or `results.json`
of the run: they record the machine and the software versions that were used.

Problems with a client itself, rather than with how it is benchmarked, belong
in that client's repository; for example, issues with `package:http`,
`package:http2` and `package:cupertino_http` belong in
[dart-lang/http](https://github.com/dart-lang/http/issues).

## Making changes

1. Install the [requirements](README.md#requirements) and run `dart pub get`.
2. Make your change, adding tests where practical. See
   [Extending the benchmarks](README.md#extending-the-benchmarks) for where
   clients, scenarios and server endpoints are defined.
3. Check it:

   ```shell
   dart format .
   dart analyze --fatal-infos
   dart test
   (cd server && gofmt -l . && go vet ./... && go test ./...)
   ```

4. Update `README.md` if you added or changed scenarios, clients or
   command-line options.
5. Send a pull request. If the change is meant to affect performance, include
   the output of `dart run bin/benchmark.dart compare` for runs made before
   and after it.
