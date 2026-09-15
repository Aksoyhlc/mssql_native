# Building for Windows

Consumers use `dart run`, `dart build cli`, or `flutter build windows`.
The desktop hook stages the committed handler and DLL payload. The rebuild
commands below are maintainer tools, not consumer installation steps.

## Packaged target

Windows x64 ships:

- `sybdb.dll` and `sybdb.lib`;
- `mssql_native.dll`.

OpenSSL 3.5.8, win-iconv and the MSVC runtime are linked statically. End users
do not install ODBC, FreeTDS, iconv, OpenSSL, or the Visual C++ Redistributable.

## Maintainer requirements

A native rebuild needs:

- Windows x64;
- Visual Studio 2022 with Desktop Development with C++ and the Windows SDK;
- **Strawberry Perl** — OpenSSL's `Configure` is a Perl script, and there is
  no way to build OpenSSL on Windows without it. GitHub's hosted Windows
  images carry it preinstalled, so this was easy to miss; a plain machine
  needs it installed:
  `choco install strawberryperl -y`  (or `winget install StrawberryPerl.StrawberryPerl`)
- CMake;
- network access on the first build: the pinned FreeTDS 1.5.16 and OpenSSL
  3.5.8 releases are downloaded and verified against
  `native/vendor/*/UPSTREAM.sha256` before anything is compiled.

NASM is **not** needed: OpenSSL is configured with `no-asm`.

Steps run under Windows PowerShell 5.1 (`shell: powershell`), which every
Windows machine has. PowerShell 7 is not required.

Flutter is needed only when the Flutter example is built.

Installing any of the above takes effect for the runner only after its
service restarts, because a Windows service keeps the PATH it was started
with. Restart it with `nssm`/Services, or run
`<runner-dir>\svc.sh`/the runner's `Runner.Listener` again.

## Rebuild

From PowerShell at the package root:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1
```

Add `-CleanDependencies` to wipe the OpenSSL and FreeTDS build directories and
compile both from scratch. Without it an existing OpenSSL prefix is reused and
the FreeTDS build is incremental, which is what makes iterating bearable -
OpenSSL alone is several minutes. Release builds should pass it.

If the staged FreeTDS files are missing, the script rebuilds them first. Force
that step with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1 -RebuildFreeTds
```

The default rebuild compiles pinned OpenSSL 3.5.8 from source. Use
`-OpenSslRoot <directory>` to supply an equivalent static build, or
`-WithoutOpenSsl` only for a private TLS-free artifact. TLS capability is
present in the release, while connection encryption remains opt-in and
defaults to `MssqlEncryption.off`.

## Character conversion

Windows has no system iconv. The release links pinned win-iconv statically so
single-byte SQL Server code pages such as CP1254 can be converted correctly.

A source rebuild expects this layout, unless `-IconvRoot` points elsewhere:

```text
native/vendor/win-iconv/
  include/iconv.h
  lib/iconv.lib
```

If a private rebuild omits win-iconv, FreeTDS falls back to its smaller built-in
conversion set and non-Latin1 data can be corrupted. Do not distribute that
artifact as equivalent to the release payload.

## TLS capability metadata

`windows/vendor/freetds/freetds_features.cmake` records whether the staged
FreeTDS has TLS. Keep it with the matching DLLs. The desktop hook and maintainer
CMake path read it before selecting or building the handler.

A rebuild requested with OpenSSL fails if configure cannot detect the TLS
backend. A library that silently accepts an encryption setting without TLS
would be worse than a failed build.

## Output

Distribute the complete Flutter release directory or `dart build cli` bundle,
not only the executable. Dart's code-asset output owns the runtime DLL layout;
the release bundle contains only `sybdb.dll` and `mssql_native.dll` from this
package.

See [Dart server and CLI](../DART_SERVER_CLI.md) and
[README · Deployment](../../README.md#deployment).
