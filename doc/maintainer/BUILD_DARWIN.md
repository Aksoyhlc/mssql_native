# Building for macOS and iOS

## Packaged targets

- macOS: arm64 (11.0+) and x86_64 (10.15+).
- iOS device: arm64 (13.0+).
- iOS simulator: arm64 (14.0+) and x86_64 (13.0+).

The package contains `sybdb.xcframework` and
`MssqlNativeBridge.xcframework` under
`darwin/mssql_native/Frameworks`. iOS Swift Package Manager and CocoaPods use
those artifacts. The desktop hook stages the macOS code assets.

OpenSSL 3.5.8 is linked statically into every shipped FreeTDS framework slice.
Apple system libiconv provides character conversion. Runtime loading does not
use Homebrew FreeTDS or OpenSSL.

## Maintainer requirements

A native rebuild needs:

- macOS with full Xcode and the macOS, iPhoneOS, and iPhoneSimulator SDKs;
- CMake, Make, pkg-config, and Perl;
- network access on the first build: the pinned FreeTDS 1.5.16 and OpenSSL
  3.5.8 releases are downloaded into `.sources/downloads` and verified
  against `native/vendor/*/UPSTREAM.sha256` before anything is compiled.

Flutter is needed only when the example application is built too.

## Rebuild commands

Rebuild all release slices without the Flutter example:

```bash
./scripts/build_darwin.sh --no-flutter
```

Add `--clean` for a clean rebuild. Without `--no-flutter`, the script also
builds the macOS example.

A private partial build can select one family:

```bash
./scripts/build_darwin.sh --no-flutter --platforms macos
./scripts/build_darwin.sh --no-flutter --platforms ios
```

Each command replaces the XCFrameworks with the selected slices. A package
release must use the default full `macos,ios` set.

TLS is enabled by default. `--without-openssl` produces a private TLS-free
build; that build rejects `MssqlEncryption.require` and `strict`.

## Cross-compilation details

The script passes explicit Autoconf build and host triples for iOS device and
simulator SDKs. This prevents configure probes from attempting to execute iOS
binaries on macOS.

OpenSSL is built per SDK and architecture, then used as static archives by
FreeTDS. Package-config lookup is constrained so a Homebrew library cannot be
linked accidentally.

## Layout and signing

The package carries pre-staged macOS dylibs under `darwin/lib/<architecture>`.
The build hook copies those when available. Its fallback thins the universal
frameworks, rewrites install names and rpaths, and applies an ad-hoc signature
to the generated dylibs. Flutter or Xcode applies final application signing.

Source macOS frameworks use versioned bundle paths; iOS frameworks use flat
bundle paths. `MssqlNativeBridge` remains the iOS handler framework name so
the runtime loader resolves the same path after hook packaging.

## Application configuration

Configure certificate trust through `MssqlRuntime.initialize(tls: ...)`.
OpenSSL does not automatically use Apple Keychain.

An iOS application connecting to a local-network server needs
`NSLocalNetworkUsageDescription` and user permission. Background suspension
can invalidate pooled sockets; the default zero validation grace period pings a
connection when it is reused.

See [TLS](../TLS.md) and [README · Deployment](../../README.md#deployment).
