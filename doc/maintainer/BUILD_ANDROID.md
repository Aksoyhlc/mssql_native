# Building for Android

Normal Flutter applications use the committed native libraries under
`android/src/main/jniLibs/<abi>/`. Gradle packages them automatically.

| ABI | Minimum API | Files |
|---|---:|---|
| `arm64-v8a` | 24 | `libsybdb.so`, `libmssql_native.so` |
| `x86_64` | 24 | `libsybdb.so`, `libmssql_native.so` |

GNU libiconv 1.18 and OpenSSL 3.5.8 are linked statically into FreeTDS. The
application does not install system OpenSSL or iconv.

## Maintainer rebuild

Rebuilding the committed artifacts requires macOS or Linux with the Android
NDK, CMake, Make, pkg-config, Perl, and network access on the first build (the
pinned FreeTDS and OpenSSL releases are downloaded and verified). Set
`ANDROID_NDK_ROOT` to select an NDK explicitly; otherwise the script searches
the Android SDK.

```bash
./scripts/build_android.sh
```

The default rebuild covers both packaged ABIs with TLS. Use
`--abis arm64-v8a` to narrow a private rebuild. `--without-openssl` creates
an intentionally TLS-free artifact that must not be described as the normal
package build.

Offline rebuilds need the expected OpenSSL and GNU libiconv source archives
already cached under `native/vendor/openssl` and `native/vendor/libiconv`.

## Application requirements

The application manifest must grant `android.permission.INTERNET`.

For verified TLS, copy a PEM CA bundle to an application-readable file and pass
that path through `MssqlTlsTrust` before opening a connection.
`MssqlTlsTrust.system()` uses OpenSSL paths; it does not bridge to Android's
native certificate store.

There is no Java/Kotlin database adapter or MethodChannel. Dart opens the
packaged libraries by soname and Android resolves them from the application.

See [TLS](../TLS.md) and
[README · Platform support](../../README.md#platform-support).
