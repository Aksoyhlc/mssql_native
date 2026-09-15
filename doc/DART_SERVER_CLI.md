# Dart server and CLI deployment

`mssql_native` supports plain Dart on packaged desktop targets. Flutter is not
required by the driver library.

## Supported flow

Use Dart 3.10 or later:

```bash
dart pub get
dart run bin/main.dart
dart build cli --target=bin/main.dart --output=build/release
```

The build hook stages the packaged native libraries automatically. Do not
build or copy native libraries by hand, set a library-path environment
variable, or copy files from the package cache.

Distribute all of `build/release/bundle/`, including its `lib/` directory.
The native assets are not embedded into the executable itself.

## Connection lifecycle

A long-running server normally initializes once, owns one pool, and closes it
before runtime shutdown:

```dart
await MssqlRuntime.instance.initialize();

final pool = MssqlConnectionPool(config);
await pool.warmUp();

try {
  await serve(pool);
} finally {
  await pool.close();
  await MssqlRuntime.instance.shutdown();
}
```

`pool.session` is appropriate for independent single operations.
`withConnection` keeps session state and temporary tables on one lease.
`pool.transaction` keeps every statement in the callback on one connection.

This lifecycle uses the plaintext default. For TLS, set the connection's
`encryption` to `require` or `strict` and pass the intended trust to
`initialize(tls: ...)`.

## Server frameworks

Serverpod, Dart Frog, shelf, and custom Dart servers use the same driver API.
Framework request handlers should share a process-level pool rather than open a
new connection per request.

A request may pass an `MssqlCancellationToken` or `MssqlQueryOptions` down
to the query layer. Do not map an HTTP retry directly to a database write
retry; the driver does not repeat arbitrary SQL.

The `example_dart_frog` directory is a packaging fixture, not a production
server architecture. It demonstrates that a Dart Frog output can pass through
`dart build cli` and retain the native assets.

## Docker

Build for Linux x64 on a Linux x64 builder. The example Dockerfile is under
`example_cli/`:

```bash
docker build --platform linux/amd64 -f example_cli/Dockerfile -t mssql-cli .
docker run --rm --env-file /path/to/database.env mssql-cli
```

Mount a private CA file at runtime and set the application to use its path. Do
not bake credentials or private certificates into the image.

The packaged Linux binary requires glibc 2.34 or later. An Alpine/musl runtime
is not a compatible target for the committed library.

## Build-machine requirements

The normal Dart SDK and destination toolchain requirements apply. The package
supplies the native libraries. The build hook uses a C compiler only in the
fallback where a prebuilt library for the target is not available.

macOS builds must run on macOS. Windows and Linux outputs must be built on
their corresponding platform; the hook is not a general cross-compiler.

## Runtime requirements

The deployed machine needs network access to SQL Server and the complete
application bundle. It does not need a SQL Server client, ODBC driver, TLS
installation, or compiler.

For what a release bundle contains and which platforms are packaged, see
[README · Deployment](../README.md#deployment).
