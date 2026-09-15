# Third-party notices

`mssql_native` is MIT licensed (see `LICENSE`), but it ships prebuilt native
binaries built from third-party projects. Those keep their own licenses, and
the terms below travel with any artifact you redistribute.

## Inventory of shipped binaries

| Component | Version | License | Where it ships |
| --- | --- | --- | --- |
| FreeTDS DB-Library (`libsybdb`) | 1.5.16 | GNU Library General Public License v2 or later | All platforms, loaded at runtime |
| OpenSSL | 3.5.8 | Apache-2.0 | Static inside `libsybdb` on every platform |
| win-iconv | commit `70a279d` | Public domain / MIT build files | Static inside `sybdb.dll` on Windows |
| GNU libiconv | 1.18 | LGPL v2.1 | Static inside `libsybdb.so` on Android |

The two copyleft components reach your application differently, and the
difference matters:

- **FreeTDS** is the separate dynamic library `libsybdb` that this package
  opens at runtime with `dlopen` (`DynamicLibrary.open`). It is never linked
  into your application, so replacing it with your own build needs no change
  to this package and no recompilation of your code.
- **GNU libiconv** is linked *statically* into `libsybdb.so`, and only on
  Android. Nothing is loaded separately there, so using your own libiconv
  means rebuilding `libsybdb.so` — which the bundled source and build scripts
  let you do.

FreeTDS also builds CT-Library (`libct`). This driver never opens it, and it
is not part of the published archive.

Linux uses the system glibc `iconv`; macOS and iOS use Apple's system
libiconv. Neither is redistributed by this package.

## Where the sources come from

This package does not carry copies of its third-party dependencies. Each
vendor directory holds only the pinned upstream URL, its SHA-256, and — for
FreeTDS — the one file this package changes:

```
native/vendor/freetds/    UPSTREAM.url  UPSTREAM.sha256  patches/  licenses/
native/vendor/openssl/    UPSTREAM.url  UPSTREAM.sha256
native/vendor/libiconv/   UPSTREAM.url  UPSTREAM.sha256  libiconv-1.18.tar.gz
```

`scripts/fetch_source.sh` fetches each archive, verifies it against the
recorded checksum, and extracts it under `.native-build/`. Building from the
upstream release rather than from a re-hosted copy means what gets compiled is
provably the dependency's own source. libiconv is the one exception: its
archive travels with the package, because Android links it statically and
GNU's download site is a weaker guarantee than a pinned local file. That
archive is the unmodified upstream release.

## Corresponding source

The complete source used to build the shipped FreeTDS binaries is two parts,
both reachable from the same place as the binaries — the git tag this package
is distributed under:

1. **The upstream FreeTDS 1.5.16 release**:
   <https://github.com/FreeTDS/freetds/releases/download/v1.5.16/freetds-1.5.16.tar.bz2>,
   SHA-256 `bc4c8264e8656180eb53e7b08ffcdfca902ceab2dfc6b5c4ef4b2394a263ec42`.
   Both are recorded in `native/vendor/freetds/UPSTREAM.url` and
   `UPSTREAM.sha256`, and `scripts/fetch_source.sh` enforces the checksum.
2. **The one file this package replaces**:
   `native/vendor/freetds/patches/src/dblib/bcp.c`, which
   `scripts/freetds_source.sh` copies over `src/dblib/bcp.c` in the extracted
   release.

Running those two scripts reproduces, byte for byte, the source tree the
shipped `libsybdb` libraries were compiled from. Nothing here is offered only
on request.

For **GNU libiconv**, the corresponding source is
`native/vendor/libiconv/libiconv-1.18.tar.gz`, the unmodified upstream release,
together with `scripts/build_libiconv_android.sh` and
`scripts/build_android.sh`. Android is the only platform that bundles it.

For **OpenSSL**, the corresponding source is
<https://github.com/openssl/openssl/releases/download/openssl-3.5.8/openssl-3.5.8.tar.gz>,
SHA-256 `a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2`,
recorded in `native/vendor/openssl/UPSTREAM.url` and `UPSTREAM.sha256`.
Apache-2.0 does not require it to be redistributed at all; the pinned
reference is given so a rebuild against the identical revision is possible.

## FreeTDS 1.5.16 — GNU Library General Public License, version 2 or later

FreeTDS provides the DB-Library implementation that speaks the TDS protocol.
`libsybdb` is the only FreeTDS library this package loads.

- License text: `native/vendor/freetds/licenses/FreeTDS-COPYING_LIB.txt`
  (the Library GPL v2 that covers the libraries). FreeTDS's command-line
  tools are GPL v2 (`FreeTDS-COPYING.txt`) and are not shipped.

### Modifications

The FreeTDS source used to build the shipped binaries is the upstream 1.5.16
release with exactly one file replaced:

- File: `src/dblib/bcp.c`, function `bcp_options()`.
- Change: it now accepts a comma-separated list of SQL Server BCP hints
  (for example `KEEP_NULLS, CHECK_CONSTRAINTS, TABLOCK`) instead of
  retaining only the first matching hint. Microsoft's driver accepts such a
  list; upstream FreeTDS silently discarded all but one hint.
- Modification date: 2026-09-05.
- The replacement file is `native/vendor/freetds/patches/src/dblib/bcp.c`. It
  carries a notice recording the change and its date, as the license's section
  2(b) requires. The modification does not alter the licensing terms of
  FreeTDS, and it adds no restriction of any kind.

## OpenSSL — Apache License 2.0

OpenSSL provides TLS for the packaged FreeTDS builds.

- License text: `native/vendor/licenses/OpenSSL-LICENSE.txt`.
- macOS, iOS, Linux, Android and Windows link **OpenSSL 3.5.8** statically into
  `libsybdb`.
- Source: `native/vendor/openssl/UPSTREAM.url` and `UPSTREAM.sha256`, checked
  by `scripts/fetch_source.sh` before every build that links it. The archive
  itself is not redistributed.

## win-iconv — MIT

Windows links win-iconv commit
`70a279dcfe6318bbe63e019e33b3230b55c19762` statically into `sybdb.dll`.
There is no separate iconv runtime DLL. The implementation is placed in the
public domain; its build files carry the MIT license from the upstream project,
<https://github.com/win-iconv/win-iconv>.

## GNU libiconv 1.18 — LGPL v2.1

Android has no system `iconv`, so GNU libiconv is built and linked statically
into the Android `libsybdb.so`. This is the one place where a copyleft library
is linked statically rather than loaded dynamically, so the material needed to
rebuild with a modified libiconv travels with the package:

- License text: `native/vendor/licenses/GNU-libiconv-COPYING.LIB`.
- Complete source: `native/vendor/libiconv/libiconv-1.18.tar.gz`, the
  unmodified upstream release.
- Upstream: <https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.18.tar.gz>
  SHA-256 `3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8`.
- Build scripts: `scripts/build_libiconv_android.sh` (builds the static
  library) and `scripts/build_android.sh` (links FreeTDS against it).

Rebuilding `libsybdb.so` with your own libiconv therefore needs nothing that
is not already in this package.

## Replacing a bundled library

Both LGPL components reach your application through `libsybdb`, which this
package loads at runtime with `dlopen` (`DynamicLibrary.open`) rather than
linking statically. To run against your own FreeTDS build — with your own
libiconv, or your own OpenSSL — build `libsybdb` for your target and replace
the file this package stages for that platform:

| Platform | File to replace |
| --- | --- |
| macOS | `darwin/lib/<arch>/libsybdb.dylib` |
| iOS | `darwin/mssql_native/Frameworks/sybdb.xcframework` |
| Linux | `linux/vendor/freetds/lib/libsybdb.so.5` |
| Windows | `windows/vendor/freetds/bin/sybdb.dll` |
| Android | `android/src/main/jniLibs/<abi>/libsybdb.so` |

Nothing else in this package needs to change: the Dart side resolves the
library by name at runtime, and the C handler library links against it
dynamically.

## Source on request

Everything above already travels with this package, or is pinned by URL and
checksum that this package records. If you would still rather receive the
corresponding source as an archive, it is available on request for three years
from the date you received this package. Open an issue at
<https://github.com/Aksoyhlc/mssql_native/issues> or write to
<aksoyhlc@gmail.com>.

## Dart dependencies

Dart package dependencies and their versions are declared in `pubspec.yaml`.
They resolve and are licensed independently through their published packages.

This notice is an inventory. It does not replace the license text shipped
with each component.
