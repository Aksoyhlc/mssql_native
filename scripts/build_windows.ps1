param(
  [ValidateSet('Debug','Release')] [string]$Configuration = 'Release',
  [switch]$RebuildFreeTds,
  # Wipe the OpenSSL and FreeTDS build directories first and compile both from
  # scratch. Off by default so iterating is cheap: the pinned inputs do not
  # change between runs, so a rebuild only needs to recompile what actually
  # changed. Release builds should pass this.
  [switch]$CleanDependencies,
  [switch]$WithOpenSsl,
  [switch]$WithoutOpenSsl,
  [string]$OpenSslRoot = '',
  [switch]$NoFlutter
)

$ErrorActionPreference = 'Stop'

# TLS capability is compiled in by default, while connections still default to
# plaintext at the Dart API. -WithoutOpenSsl creates a reduced custom build.
$UseOpenSsl = -not $WithoutOpenSsl

$Root = Split-Path -Parent $PSScriptRoot
$Vendor = Join-Path $Root 'windows\vendor\freetds'
$Required = @(
  (Join-Path $Vendor 'include\sybdb.h'),
  (Join-Path $Vendor 'include\tds_sysdep_public.h'),
  (Join-Path $Vendor 'lib\sybdb.lib'),
  (Join-Path $Vendor 'bin\sybdb.dll')
)
$Missing = @($Required | Where-Object { -not (Test-Path $_) })
$Features = Join-Path $Vendor 'freetds_features.cmake'
$ExpectedFeature = "set(MSSQL_NATIVE_HAS_TLS $(if ($UseOpenSsl) { 'ON' } else { 'OFF' }))"
$FeaturesMatch = (Test-Path $Features) -and
  (Select-String -Path $Features -Pattern $ExpectedFeature -SimpleMatch -Quiet)

if ($RebuildFreeTds -or $Missing.Count -gt 0 -or -not $FeaturesMatch) {
  Write-Host 'FreeTDS needs rebuilding (requested, missing files or changed TLS mode)...' -ForegroundColor Cyan
  $InvokeArgs = @{}
  if ($CleanDependencies) { $InvokeArgs.Clean = $true }
  if ($UseOpenSsl) {
    if ([string]::IsNullOrWhiteSpace($OpenSslRoot)) {
      $OpenSslRoot = Join-Path $Root '.native-build\openssl\windows-prefix'
      # -Clean only when asked: build_openssl_windows.ps1 otherwise reuses a
      # prefix that already holds the headers and both static libraries.
      $OpenSslArgs = @{ Prefix = $OpenSslRoot }
      if ($CleanDependencies) { $OpenSslArgs.Clean = $true }
      & "$PSScriptRoot\build_openssl_windows.ps1" @OpenSslArgs
    }
    $InvokeArgs.WithOpenSsl = $true
    $InvokeArgs.OpenSslRoot = $OpenSslRoot
  }
  & "$PSScriptRoot\build_freetds_from_source.ps1" @InvokeArgs
}


$BridgeBuild = Join-Path $Root '.native-build\windows-bridge-x64'
$NativeRoot = Join-Path $Root 'native'
# CMake mis-parses backslashes in -D values on Windows (they read as escape
# sequences), which corrupts the FreeTDS paths. Pass forward slashes, which
# CMake accepts on every platform.
$FreeTdsInclude = (Join-Path $Vendor 'include').Replace('\', '/')
$FreeTdsLibrary = (Join-Path $Vendor 'lib\sybdb.lib').Replace('\', '/')
$BridgeArgs = @(
  '-S', $NativeRoot,
  '-B', $BridgeBuild,
  '-G', 'Visual Studio 17 2022',
  '-A', 'x64',
  '-DCMAKE_POLICY_DEFAULT_CMP0091=NEW',
  '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded',
  "-DCMAKE_C_FLAGS_RELEASE=/O2 /Ob2 /DNDEBUG /Brepro /pathmap:$Root=.",
  "-DFREETDS_INCLUDE_DIR=$FreeTdsInclude",
  "-DFREETDS_LIBRARY=$FreeTdsLibrary",
  "-DMSSQL_NATIVE_HAS_TLS=$(if ($UseOpenSsl) { 'ON' } else { 'OFF' })"
)
& cmake @BridgeArgs
if ($LASTEXITCODE -ne 0) { throw "Native bridge configure failed with exit code $LASTEXITCODE" }
& cmake --build $BridgeBuild --config $Configuration --target mssql_native -- /m
if ($LASTEXITCODE -ne 0) { throw "Native bridge build failed with exit code $LASTEXITCODE" }

# The handler ships built, so that a consumer of the package needs no C
# toolchain: the Dart build hook stages this file instead of compiling
# native/src/handlers.c on the user's machine, exactly as the Apple and Android
# builds do with their own prebuilt binaries.
$BridgeDll = Get-ChildItem -Path $BridgeBuild -Recurse -Filter 'mssql_native.dll' |
  Select-Object -First 1
if (-not $BridgeDll) { throw 'mssql_native.dll was not built.' }
$StagedBin = Join-Path $Root 'windows\bin'
New-Item -ItemType Directory -Force -Path $StagedBin | Out-Null
Copy-Item $BridgeDll.FullName (Join-Path $StagedBin 'mssql_native.dll') -Force
Write-Host "Staged handler: $(Join-Path $StagedBin 'mssql_native.dll') ($($BridgeDll.Length) bytes)"

# Remove the legacy dynamic CRT only after both replacement DLLs were built
# successfully, so an interrupted build cannot damage the existing payload.
$LegacyRuntime = Join-Path $Root 'windows\redist\vcruntime140.dll'
if (Test-Path $LegacyRuntime) {
  Remove-Item $LegacyRuntime -Force
}

if ($NoFlutter) {
  Write-Host "Windows FreeTDS and handler library build completed (TLS: $(if ($UseOpenSsl) { 'OpenSSL' } else { 'disabled' }))." -ForegroundColor Green
  return
}

Push-Location $Root
try {
  & "$PSScriptRoot\verify_freetds.ps1"
  flutter pub get
  if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed with exit code $LASTEXITCODE" }

  $Example = Join-Path $Root 'example'
  if (-not (Test-Path (Join-Path $Example 'windows\CMakeLists.txt'))) {
    Push-Location $Example
    try { flutter create --platforms=windows . }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "Could not generate the Windows example runner." }
  }
  Push-Location $Example
  try {
    flutter pub get
    if ($Configuration -eq 'Release') { flutter build windows --release }
    else { flutter build windows --debug }
  } finally {
    Pop-Location
  }
  if ($LASTEXITCODE -ne 0) { throw "Flutter Windows example build failed with exit code $LASTEXITCODE" }
} finally {
  Pop-Location
}
