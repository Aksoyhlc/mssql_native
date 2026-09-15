param(
  [string]$Source = '',
  [string]$BuildDirectory = '',
  [string]$Generator = 'Visual Studio 17 2022',
  [switch]$Clean,
  [switch]$WithOpenSsl,
  [string]$OpenSslRoot = '',
  # Prebuilt static win-iconv (iconv.h / iconv.lib). Windows has no system
  # iconv, so without this FreeTDS falls back to its built-in converter which
  # only handles ASCII/ISO-8859-1/UTF-8/UCS-2/CP1252 and MANGLES CHAR/VARCHAR
  # columns whose collation is a non-Latin1 code page (e.g. Turkish_CI_AS /
  # CP1254: İ/Ş/Ğ become Ý/Þ/Ð). Point this at a win-iconv build to get full,
  # universal single-byte code-page support. See doc/maintainer/BUILD_WINDOWS.md.
  [string]$IconvRoot = ''
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
# The repository carries no FreeTDS copy: the pinned upstream release is
# downloaded and verified, then the one file this package changes is copied
# over it. The checksum identifies the release; the changed file is kept here
# as a whole file for review.
. "$PSScriptRoot\FetchSource.ps1"
$FreetdsVendor = Join-Path $Root 'native\vendor\freetds'
$FreetdsPatch = Join-Path $FreetdsVendor 'patches\src\dblib\bcp.c'
if (-not (Test-Path $FreetdsPatch)) { throw "FreeTDS patch not found: $FreetdsPatch" }

$BundledSource = Get-SourceTree -Root $Root -Name 'freetds'

# FreeTDS-derived build trees are stale whenever the source path, the upstream
# release or the patch changes: they record the path they were configured
# against, and a replaced file whose timestamp is not newer than its object
# would be skipped by the build. OpenSSL-derived trees and downloaded archives
# are kept.
$Native = Join-Path $Root '.native-build'
$PatchSha = (Get-FileHash $FreetdsPatch -Algorithm SHA256).Hash.ToLowerInvariant()
$UpstreamSha = (((Get-Content (Join-Path $FreetdsVendor 'UPSTREAM.sha256') -First 1).Trim() -split '\s+')[0])
$Fingerprint = "$BundledSource $UpstreamSha $PatchSha"
$Marker = Join-Path $Native 'freetds-source.fingerprint'
$Have = if (Test-Path $Marker) { (Get-Content $Marker -First 1).Trim() } else { '' }
if ($Have -ne $Fingerprint) {
  Get-ChildItem -Path $Native -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @('sources', 'downloads') -and $_.Name -notlike 'openssl*' } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  Set-Content -Path $Marker -Value $Fingerprint -Encoding ascii
}
Copy-Item $FreetdsPatch (Join-Path $BundledSource 'src\dblib\bcp.c') -Force

if ([string]::IsNullOrWhiteSpace($IconvRoot)) {
  $IconvRoot = Join-Path $Root 'native\vendor\win-iconv'
}

if ([string]::IsNullOrWhiteSpace($Source)) {
  $Source = $BundledSource
}
if (-not (Test-Path (Join-Path $Source 'CMakeLists.txt'))) {
  throw "FreeTDS source tree not found: $Source"
}
$Source = (Resolve-Path $Source).Path

if ([string]::IsNullOrWhiteSpace($BuildDirectory)) {
  $BuildDirectory = Join-Path $Root '.native-build\freetds-1.5.16-x64'
}
if ($Clean -and (Test-Path $BuildDirectory)) {
  Remove-Item $BuildDirectory -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $BuildDirectory | Out-Null

# Stage win-iconv into the FreeTDS source tree. FreeTDS's CMakeLists enables
# HAVE_ICONV and links iconv when it finds <source>/iconv/lib/iconv.lib +
# <source>/iconv/include/iconv.h. Copy a prebuilt win-iconv there before
# configuring so single-byte code pages beyond CP1252 (Turkish CP1254, etc.)
# convert correctly instead of degrading to ISO-8859-1.
$IconvLibSrc = Join-Path $IconvRoot 'lib\iconv.lib'
$IconvHdrSrc = Join-Path $IconvRoot 'include\iconv.h'
if ((Test-Path $IconvLibSrc) -and (Test-Path $IconvHdrSrc)) {
  $StageLib = Join-Path $Source 'iconv\lib'
  $StageInc = Join-Path $Source 'iconv\include'
  New-Item -ItemType Directory -Force -Path $StageLib, $StageInc | Out-Null
  Copy-Item $IconvLibSrc (Join-Path $StageLib 'iconv.lib') -Force
  Copy-Item $IconvHdrSrc (Join-Path $StageInc 'iconv.h') -Force
  Write-Host "win-iconv staged from: $IconvRoot (full code-page support enabled)" -ForegroundColor Cyan
} else {
  Write-Warning ("win-iconv not found at $IconvRoot. FreeTDS will use its built-in " +
    "converter, which only handles ASCII/ISO-8859-1/UTF-8/UCS-2/CP1252. CHAR/VARCHAR " +
    "columns with non-Latin1 collations (e.g. Turkish_CI_AS / CP1254) will be corrupted " +
    "(İ/Ş/Ğ -> Ý/Þ/Ð). See doc/maintainer/BUILD_WINDOWS.md to enable full support.")
}

$CmakeArgs = @(
  '-S', $Source,
  '-B', $BuildDirectory,
  '-G', $Generator,
  '-A', 'x64',
  '-DCMAKE_BUILD_TYPE=Release',
  # A system OpenSSL must not be able to substitute for the pinned one. CMake's
  # FindOpenSSL needs a library per configuration, and when it cannot find a
  # debug variant in the pinned prefix it looks elsewhere: on the self-hosted
  # runner it picked up
  # C:\Program Files\OpenSSL-Win64\lib\VC\static\libcrypto64MDd.lib - a /MDd
  # library, linked into a /MT probe against /MT headers. OPENSSL_LIBRARIES
  # then carried both, the linker honoured the debug one, and all four probes
  # failed, so FreeTDS fell back to pre-1.1 shims that do not compile against
  # OpenSSL 3.x.
  #
  # These are the standard Windows install locations for OpenSSL. Ignoring them
  # leaves the pinned prefix as the only candidate.
  #
  # Pinning the configuration instead does not work: CMAKE_CONFIGURATION_TYPES
  # and CMAKE_TRY_COMPILE_CONFIGURATION together leave try_compile asking for a
  # configuration the generated project does not define, and configure then
  # fails in CheckTypeSize with "Cannot copy output executable ''".
  '-DCMAKE_IGNORE_PATH=C:\Program Files\OpenSSL-Win64;C:\Program Files\OpenSSL-Win32;C:\Program Files (x86)\OpenSSL-Win64;C:\OpenSSL-Win64;C:\OpenSSL-Win32',
  '-DCMAKE_POLICY_DEFAULT_CMP0091=NEW',
  '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded',
  # The extracted sources live in .sources, outside .native-build, so mapping
  # the repository root is enough and the result carries no build-directory
  # name. A second, overlapping /pathmap for the source tree was tried and
  # removed: MSVC did not apply either map on the hosted runner, and one
  # unambiguous map is what the working configuration used.
  "/DCMAKE_C_FLAGS_RELEASE=/O2 /Ob2 /DNDEBUG /Brepro /pathmap:$Root=.",
  '-DENABLE_KRB5=OFF',
  '-DENABLE_ODBC_MARS=OFF',
  '-DENABLE_MSDBLIB=ON'
)

if ($WithOpenSsl) {
  $CmakeArgs += '-DWITH_OPENSSL=ON'
  if (-not [string]::IsNullOrWhiteSpace($OpenSslRoot)) {
    if (-not (Test-Path $OpenSslRoot)) { throw "OpenSSL root not found: $OpenSslRoot" }
    $OpenSslRoot = (Resolve-Path $OpenSslRoot).Path

    # OPENSSL_ROOT_DIR alone is not enough. CMake's FindOpenSSL also consults
    # its own hints and the registry, and on a machine with a second OpenSSL
    # installed it returned a combined list:
    #   optimized;<ours>/lib/libcrypto.lib;debug;<elsewhere>/libcrypto64MDd.lib
    # FreeTDS then feeds OPENSSL_LIBRARIES into check_function_exists, the
    # "optimized"/"debug" keywords break that link test, HAVE_BIO_GET_DATA
    # comes back 0, and FreeTDS compiles its pre-1.1 BIO shim against OpenSSL
    # 3.x headers - which fails, because bio_st is opaque there. Pinning the
    # three variables FindOpenSSL actually reads leaves nothing to search.
    $OpenSslInclude = Join-Path $OpenSslRoot 'include'
    $OpenSslCrypto = Join-Path $OpenSslRoot 'lib\libcrypto.lib'
    $OpenSslSsl = Join-Path $OpenSslRoot 'lib\libssl.lib'
    foreach ($Required in @(
      (Join-Path $OpenSslInclude 'openssl\ssl.h'), $OpenSslCrypto, $OpenSslSsl
    )) {
      if (-not (Test-Path $Required)) { throw "Missing from the OpenSSL prefix: $Required" }
    }
    $CmakeArgs += "-DOPENSSL_ROOT_DIR=$OpenSslRoot"
    $CmakeArgs += "-DOPENSSL_INCLUDE_DIR=$OpenSslInclude"
    $CmakeArgs += "-DOPENSSL_CRYPTO_LIBRARY=$OpenSslCrypto"
    $CmakeArgs += "-DOPENSSL_SSL_LIBRARY=$OpenSslSsl"
    $CmakeArgs += '-DOPENSSL_USE_STATIC_LIBS=TRUE'
  }
} else {
  # Default offline build has no external TLS DLL dependency.
  $CmakeArgs += '-DWITH_OPENSSL=OFF'
}

Write-Host "Configuring bundled FreeTDS from: $Source" -ForegroundColor Cyan
& cmake @CmakeArgs
if ($LASTEXITCODE -ne 0) {
  # CMake caches probe results, so a configure that failed leaves those answers
  # behind and the next attempt inherits them instead of probing again. Once
  # the build directory started surviving between runs, that turned one bad
  # configure into a permanent one: every later run failed at SELECT_TYPE with
  # "EQUAL 2 Unknown arguments", from the cached empty SIZEOF_SHORT, no matter
  # what the script was changed to.
  if (Test-Path $BuildDirectory) {
    Write-Host "Removing $BuildDirectory so the next run re-probes." -ForegroundColor Yellow
    Remove-Item $BuildDirectory -Recurse -Force -ErrorAction SilentlyContinue
  }
  throw "FreeTDS CMake configure failed with exit code $LASTEXITCODE"
}

# FreeTDS probes these four OpenSSL functions at configure time and, when one
# is missing, compiles a pre-1.1 compatibility shim instead. Against OpenSSL
# 3.x those shims do not build - bio_st and rsa_st are opaque - so the failure
# surfaces much later as a wall of C2037 errors in tls.c, saying nothing about
# OpenSSL detection. Fail here instead, where the cause is obvious.
#
# They come back missing whenever the link probe cannot run, and the probe
# links OPENSSL_LIBRARIES, so anything that makes FindOpenSSL return more than
# this prefix's two static libraries - a stray system OpenSSL, for instance -
# breaks all four at once. The pinning above is what prevents it.
if ($WithOpenSsl) {
  $Generated = Join-Path $BuildDirectory 'include\config.h'
  if (-not (Test-Path $Generated)) { throw "Expected $Generated after configure." }
  $Config = Get-Content $Generated -Raw
  $MissingProbes = @()
  foreach ($Probe in @('HAVE_BIO_GET_DATA', 'HAVE_RSA_GET0_KEY', 'HAVE_ASN1_STRING_GET0_DATA', 'HAVE_SSL_SET_ALPN_PROTOS')) {
    if ($Config -notmatch "(?m)^#define $Probe 1") { $MissingProbes += $Probe }
  }
  if ($MissingProbes.Count -gt 0) {
    # Print what the probe actually did, rather than only that it failed. The
    # answer is in the cache (which OpenSSL FindOpenSSL settled on) and in the
    # configure log (why the link failed); without them the next person starts
    # from the same guess we did.
    Write-Host '--- OpenSSL as CMake resolved it ---' -ForegroundColor Yellow
    $Cache = Join-Path $BuildDirectory 'CMakeCache.txt'
    if (Test-Path $Cache) {
      Select-String -Path $Cache -Pattern '^OPENSSL_' |
        ForEach-Object { Write-Host "    $($_.Line)" }
    } else {
      Write-Host "    (no $Cache)"
    }

    Write-Host '--- why the probe link failed ---' -ForegroundColor Yellow
    $Logs = @(
      (Join-Path $BuildDirectory 'CMakeFiles\CMakeConfigureLog.yaml'),
      (Join-Path $BuildDirectory 'CMakeFiles\CMakeError.log')
    ) | Where-Object { Test-Path $_ }
    if ($Logs.Count -eq 0) {
      Write-Host '    (no configure log found)'
    }
    foreach ($Log in $Logs) {
      Write-Host "    from $Log"
      # Both logs are appended across runs, so the block to read is the LAST
      # one for the probe that fails first - a plain tail shows whichever
      # unrelated check happened to run last (vasprintf, typically).
      $Lines = Get-Content $Log -ErrorAction SilentlyContinue
      $Start = -1
      for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        if ($Lines[$i] -match 'BIO_get_data') { $Start = $i; break }
      }
      if ($Start -lt 0) { $Start = [Math]::Max(0, $Lines.Count - 30) }
      $End = [Math]::Min($Lines.Count, $Start + 30)
      for ($i = $Start; $i -lt $End; $i++) { Write-Host "      $($Lines[$i].TrimEnd())" }
    }

    # CMake caches the probe results, so a configure that failed for a reason
    # now fixed would keep reporting the old answer from the build directory -
    # which is exactly what happened once this directory started surviving
    # between runs. Remove it so the next attempt probes again.
    Write-Host "Removing $BuildDirectory so the next run re-probes." -ForegroundColor Yellow
    Remove-Item $BuildDirectory -Recurse -Force -ErrorAction SilentlyContinue

    throw @"
FreeTDS did not detect OpenSSL properly: $($MissingProbes -join ', ') undefined in $Generated.
It will now try to compile pre-1.1 compatibility shims against OpenSSL 3.x and fail on opaque structs.
This means the configure-time link probe against OPENSSL_LIBRARIES failed; the details above say why.
"@
  }
  Write-Host "OpenSSL probes detected: BIO_get_data, RSA_get0_key, ASN1_STRING_get0_data, SSL_set_alpn_protos" -ForegroundColor Green
}

& cmake --build $BuildDirectory --config Release --target sybdb -- /m
if ($LASTEXITCODE -ne 0) { throw "FreeTDS build failed with exit code $LASTEXITCODE" }

$Dll = Get-ChildItem $BuildDirectory -Recurse -Filter 'sybdb.dll' |
  Where-Object { $_.FullName -match '[\\/]Release[\\/]' } |
  Select-Object -First 1
$Lib = Get-ChildItem $BuildDirectory -Recurse -Filter 'sybdb.lib' |
  Where-Object { $_.FullName -match '[\\/]Release[\\/]' } |
  Select-Object -First 1
if (-not $Dll -or -not $Lib) {
  throw 'FreeTDS build completed but sybdb.dll/sybdb.lib could not be located.'
}

$Vendor = Join-Path $Root 'windows\vendor\freetds'
$Include = Join-Path $Vendor 'include'
$Bin = Join-Path $Vendor 'bin'
$LibDir = Join-Path $Vendor 'lib'
$Licenses = Join-Path $Vendor 'licenses'

foreach ($Dir in @($Include, $Bin, $LibDir, $Licenses)) {
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
}

# The release is self-contained through static OpenSSL, iconv and MSVC runtime
# linkage. Remove DLLs left by an older dynamic build before staging the new
# payload, otherwise a checkout can accidentally publish dependencies it no
# longer imports.
Get-ChildItem $Bin -Filter '*.dll' -ErrorAction SilentlyContinue |
  Remove-Item -Force

# Recreate headers so stale generated files cannot survive an upgrade.
Get-ChildItem $Include -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Copy-Item (Join-Path $Source 'include\*') $Include -Recurse -Force

# FreeTDS CMake generates public headers such as tds_sysdep_public.h here.
$GeneratedInclude = Join-Path $BuildDirectory 'include'
if (Test-Path $GeneratedInclude) {
  Copy-Item (Join-Path $GeneratedInclude '*') $Include -Recurse -Force
}
if (-not (Test-Path (Join-Path $Include 'tds_sysdep_public.h'))) {
  throw 'Generated public header tds_sysdep_public.h was not found after the build.'
}

Copy-Item $Dll.FullName (Join-Path $Bin 'sybdb.dll') -Force
Copy-Item $Lib.FullName (Join-Path $LibDir 'sybdb.lib') -Force

$Pdb = Get-ChildItem $Dll.DirectoryName -Filter 'sybdb.pdb' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($Pdb) { Copy-Item $Pdb.FullName (Join-Path $Bin 'sybdb.pdb') -Force }

# Dynamic OpenSSL is deliberately unsupported by the release: the code-asset
# payload is exactly sybdb.dll plus mssql_native.dll. Import names appear as
# ASCII in the PE, so this check needs no dumpbin dependency.
if ($WithOpenSsl) {
  $SybdbStaged = Join-Path $Bin 'sybdb.dll'
  $Ascii = [System.Text.Encoding]::ASCII.GetString(
    [System.IO.File]::ReadAllBytes($SybdbStaged))
  $Needed = New-Object System.Collections.Generic.List[string]
  foreach ($Prefix in @('libssl', 'libcrypto', 'ssleay', 'libeay')) {
    foreach ($Match in [regex]::Matches($Ascii, "$Prefix[-_0-9A-Za-z]*\.dll")) {
      if (-not $Needed.Contains($Match.Value)) { $Needed.Add($Match.Value) }
    }
  }

  if ($Needed.Count -eq 0) {
    Write-Host 'sybdb.dll has no dynamic OpenSSL dependency (static link).' -ForegroundColor Green
  } else {
    throw "sybdb.dll links OpenSSL dynamically: $($Needed -join ', '). Use a static OpenSSL build."
  }
}

foreach ($LicenseName in @('COPYING.txt', 'COPYING_LIB.txt')) {
  $LicensePath = Join-Path $Source $LicenseName
  if (Test-Path $LicensePath) {
    Copy-Item $LicensePath (Join-Path $Licenses "FreeTDS-$LicenseName") -Force
  }
}

& "$PSScriptRoot\verify_freetds.ps1"
Write-Host 'FreeTDS 1.5.16 DB-Library staged successfully.' -ForegroundColor Green
if ($WithOpenSsl) {
  # A build that quietly lost OpenSSL connects happily and never encrypts,
  # which is worth refusing rather than reporting.
  $ConfigHeader = Join-Path $BuildDirectory 'include\config.h'
  if (-not (Test-Path $ConfigHeader) -or -not (Select-String -Path $ConfigHeader -Pattern '^#define HAVE_OPENSSL 1' -Quiet)) {
    throw 'OpenSSL was requested but not detected; refusing to ship a build that cannot encrypt.'
  }
  Write-Host 'TLS is enabled (OpenSSL).' -ForegroundColor Green
} else {
  Write-Host 'TLS was disabled. Use -WithOpenSsl with an offline OpenSSL build if encrypted SQL Server connections are required.' -ForegroundColor Yellow
}

# Consumed by Flutter's Windows CMake before it compiles the handler library.
@(
  '# Generated alongside the staged FreeTDS library; keep with its binaries.'
  "set(MSSQL_NATIVE_HAS_TLS $(if ($WithOpenSsl) { 'ON' } else { 'OFF' }))"
) | Set-Content -Path (Join-Path $Vendor 'freetds_features.cmake') -Encoding ascii
