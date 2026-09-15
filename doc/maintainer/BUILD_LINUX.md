# Building for Linux

Consumers use `dart run`, `dart build cli`, or `flutter build linux`.
The desktop hook stages the committed handler and FreeTDS libraries. The
commands below are for maintainers refreshing native artifacts, not for
installing the Dart package.

## Packaged target

- Linux x64.
- glibc 2.34 or later.
- `libsybdb.so.5` for FreeTDS DB-Library.
- `libmssql_native.so` for callbacks, cancellation state, and capability
  reporting.

There is no ODBC registration or system FreeTDS dependency.

## Maintainer requirements

A rebuild needs a Linux host or container with GCC/Clang, CMake, Make,
pkg-config, Perl, and standard development headers. The FreeTDS 1.5.16 source
is bundled. The OpenSSL source archive is cached under
`native/vendor/openssl` or obtained by the rebuild script.

## Rebuild

```bash
./scripts/build_linux.sh
```

Build only the native artifacts:

```bash
./scripts/build_linux.sh --no-flutter
```

Use `--clean` for a clean rebuild.

OpenSSL is enabled by default and linked statically into `libsybdb.so`.
Character conversion comes from glibc iconv. `--without-openssl` produces a
private TLS-free build.

The rebuild writes
`linux/vendor/freetds/freetds_features.cmake`. Keep it beside the matching
native libraries: the desktop hook and maintainer CMake path use it to ensure
that the handler reports the same TLS capability as FreeTDS.

## Consumer bundle

The hook packages a real `libsybdb.so.5` file with the SONAME required by the
handler. The handler uses an `$ORIGIN`-relative lookup, so the target machine
does not need a global FreeTDS installation.

Distribute the complete SDK output bundle. Build release binaries on the oldest
Linux distribution whose glibc version you intend to support.

See [Dart server and CLI](../DART_SERVER_CLI.md) and
[README · Deployment](../../README.md#deployment).
