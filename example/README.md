# Examples

`basic.dart` is the compact package example. It shows runtime initialization,
connection ownership, parameter binding, and cleanup.
Replace its connection settings and select a trust source appropriate for the
deployment before running it.

The rest of this directory is a larger Flutter development fixture. It
demonstrates a connection lifecycle, a parameterized query, Unicode data, and
visible error reporting.

Before running it, replace the placeholder connection settings in
`lib/main.dart` with development credentials. The current UI contains a
single action button; it does not collect credentials.

The driver initializes its runtime automatically when the first connection is
opened. Encryption defaults to `off`, so the current fixture uses plaintext.
A real application that selects `require` or `strict` must initialize
`MssqlRuntime` with an appropriate process-wide `MssqlTlsTrust` first.

From this directory:

```console
flutter pub get
flutter run
```

Supported Flutter targets are Windows x64, Linux x64, macOS arm64/x86_64, iOS
arm64 device and arm64/x86_64 simulator, and Android arm64-v8a/x86_64. Web is
not supported because the driver uses `dart:ffi` and packaged native
libraries.

See [TLS configuration](../doc/TLS.md) and the package
[README](../README.md) before adapting the example for deployment.
