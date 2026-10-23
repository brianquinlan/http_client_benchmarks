# flutter_runner

A Flutter app that runs the benchmarks on Android devices, where it can also
benchmark `OkHttpClient` ([`package:ok_http`](https://pub.dev/packages/ok_http))
and `CronetClient` ([`package:cronet_http`](https://pub.dev/packages/cronet_http)).

Don't run it directly: the benchmark command-line tool starts the benchmark
server on the device, builds this app in profile mode and runs it with
`flutter drive`. See
[Benchmarking on Android](../README.md#benchmarking-on-android).

* `integration_test/benchmark_test.dart` runs the benchmarks on the device.
* `test_driver/integration_test.dart` receives the results on the computer.
* `lib/android_clients.dart` defines the Android-only clients.
* `android/app/src/main/res/xml/network_security_config.xml` trusts the
  benchmark CA, but only for connections to the server on the device.
