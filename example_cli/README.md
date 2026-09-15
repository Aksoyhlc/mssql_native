# Standalone Dart CLI

Requires Dart 3.10+; Flutter is not required. Supported desktop targets:
Linux x64 (glibc 2.34+), Windows x64, macOS arm64/x64.

From this directory:

```sh
dart pub get
dart run bin/main.dart
```

Set `MSSQL_HOST`, `MSSQL_DATABASE`, `MSSQL_USERNAME`, `MSSQL_PASSWORD` first.
Optional: `MSSQL_PORT` (1433 by default).

Set `MSSQL_CA_FILE` to a trusted PEM CA to encrypt the session: with it the
example requests encryption and the driver fails closed, so a certificate it
cannot authenticate ends the connection rather than downgrading it. Without it
the example connects in plaintext and says so on stderr — suitable for a local
container, not for anything reachable off the machine.

No native-library environment variable or manual library copy is needed.

Produce a distributable application with:

```sh
dart build cli --target=bin/main.dart --output=build/release
```

Distribute **all of `build/release/bundle/`**, not only `bin/main` (`main.exe`
on Windows). The `lib/` directory contains the native code assets. Build for
the destination OS/architecture; this is not a Mac-to-Linux cross compiler.

The build hook stages the packaged native libraries automatically. macOS
builds need Xcode command-line tools. Windows and Linux use a C toolchain only
in the fallback where a prebuilt library for the target is unavailable. These
are build-machine tools, not tools for end users. The Docker builder already
supplies its Linux toolchain.

From the repository root:

```sh
docker build --platform linux/amd64 -f example_cli/Dockerfile -t mssql-cli .
docker run --rm --env-file /path/to/database.env mssql-cli
```

If using a CA file in Docker, mount it and set `MSSQL_CA_FILE` to its path
inside the container. Do not bake credentials into the image.

The Dockerfile demonstrates the package in a plain Dart image; the Flutter
`example/` app is unrelated. Serverpod and Dart Frog use the same native-asset
bundle mechanism; see `doc/DART_SERVER_CLI.md` for their build boundaries.
