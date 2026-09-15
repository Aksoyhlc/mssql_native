# FreeTDS layout

The repository does not carry a FreeTDS copy. `native/vendor/freetds/` holds
only what is needed to obtain and rebuild it:

```
UPSTREAM.url       https://github.com/FreeTDS/freetds/releases/download/v1.5.16/freetds-1.5.16.tar.bz2
UPSTREAM.sha256    bc4c8264e8656180eb53e7b08ffcdfca902ceab2dfc6b5c4ef4b2394a263ec42  freetds-1.5.16.tar.bz2
patches/src/dblib/bcp.c   the one file this package replaces
licenses/                 COPYING_LIB.txt and COPYING.txt
```

`scripts/fetch_source.sh` downloads that release into
`.sources/downloads/`, verifies the checksum, and extracts it under
`.sources/`. `scripts/freetds_source.sh` then copies
`patches/src/dblib/bcp.c` over `src/dblib/bcp.c`, so the tree a build compiles
is upstream 1.5.16 plus exactly one declared change. Building from FreeTDS's
own release rather than from a vendored copy means the unmodified 2137 files
are provably FreeTDS's, and the modification is reviewable as a whole file
instead of a diff buried in thousands.

Prebuilt libraries for supported targets are committed so normal Dart and
Flutter consumers do not rebuild FreeTDS.

## Changing the vendored source

Edit `native/vendor/freetds/patches/src/dblib/bcp.c` directly and keep the
change notice at the top of the file current - the GNU Library GPL's section
2(b) requires the modified file to state that it was changed and when.

A change is picked up automatically: `freetds_source.sh` fingerprints the
source path, the upstream checksum and the patch file, and discards
FreeTDS-derived build trees under `.native-build/` whenever that fingerprint
changes. They have to go, because each records the path it was configured
against, and a replaced file whose timestamp is not newer than its object
would otherwise be skipped by `make`.

To check the patch still applies cleanly to the pinned release:

```bash
source scripts/fetch_source.sh && source scripts/freetds_source.sh
echo "$(freetds_source "$PWD")"
diff -rq .sources/freetds-1.5.16 <unpacked-upstream-release>
# bcp.c is the only file that may differ
```

Verify the OpenSSL source the same way, with `scripts/openssl_source.sh`; it
is unmodified upstream, so nothing should differ.

| Platform | Packaged files |
|---|---|
| Windows | `windows/vendor/freetds` |
| Linux | `linux/vendor/freetds` |
| macOS and iOS | `darwin/mssql_native/Frameworks` |
| Android | `android/src/main/jniLibs` |

Desktop native assets are prepared by `hook/build.dart` during supported Dart
and Flutter builds. Android and iOS use their packaged plugin artifacts.

## Maintainer rebuilds

These commands refresh prebuilt artifacts; application consumers do not run
them:

```powershell
scripts\build_windows.ps1 -RebuildFreeTds
```

```bash
./scripts/build_linux.sh --no-flutter
./scripts/build_darwin.sh --no-flutter
./scripts/build_android.sh
```

TLS support is included on every packaged platform. OpenSSL is linked
statically into FreeTDS on Apple platforms, Linux, Android and Windows. End
users do not install OpenSSL separately.

Windows and Linux keep `freetds_features.cmake` beside their FreeTDS payload.
The desktop build hook and maintainer CMake entry points read this metadata
when building the small handler library. Rebuild output remains under
`.native-build`; the hook writes only to the SDK-provided output directory.

For consumer packaging, see [README · Deployment](../../README.md#deployment).
For trust configuration, see [TLS](../TLS.md).
