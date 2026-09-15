param(
  [string]$Prefix = '',
  [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Version = '3.5.8'
$Build = Join-Path $Root '.native-build\openssl\windows-x64'
$Stage = Join-Path $Build 'stage'
$LogicalPrefix = 'C:\mssql-native\openssl'

if ([string]::IsNullOrWhiteSpace($Prefix)) {
  $Prefix = Join-Path $Root '.native-build\openssl\windows-prefix'
}

# Reuse an already-built prefix unless a clean rebuild was asked for. OpenSSL
# takes minutes to compile and its inputs are pinned, so rebuilding it on
# every iteration buys nothing - and on a self-hosted machine those minutes
# are the wall clock a maintainer waits through. -Clean still forces the full
# path, which is what a release build should use.
if (-not $Clean) {
  $Required = @(
    (Join-Path $Prefix 'include\openssl\ssl.h'),
    (Join-Path $Prefix 'lib\libcrypto.lib'),
    (Join-Path $Prefix 'lib\libssl.lib')
  )
  if (@($Required | Where-Object { -not (Test-Path $_) }).Count -eq 0) {
    Write-Host "OpenSSL $Version already staged at $Prefix (pass -Clean to rebuild)." -ForegroundColor Green
    return
  }
}

if ($Clean) {
  foreach ($Path in @($Build, $Prefix)) {
    if (Test-Path $Path) { Remove-Item $Path -Recurse -Force }
  }
}

# The repository carries no OpenSSL copy: the pinned upstream release is
# downloaded into .sources and verified against the checksum recorded in
# native\vendor\openssl before it is built.
. "$PSScriptRoot\FetchSource.ps1"
$Source = Get-SourceTree -Root $Root -Name 'openssl'

# Each tool is missing for its own reason, and the remediation differs, so say
# which one it is. Reporting "run from a developer shell" for perl.exe sent a
# self-hosted run looking in the wrong place: Perl is simply not installed on
# a plain Windows machine, while cl.exe and nmake.exe are what the Visual
# Studio developer environment provides.
foreach ($Command in @('perl.exe', 'nmake.exe', 'cl.exe')) {
  if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
    switch ($Command) {
      'perl.exe' {
        throw "perl.exe is required: OpenSSL's Configure is a Perl script. Install Strawberry Perl (choco install strawberryperl -y) and restart the runner service so it sees the new PATH."
      }
      default {
        throw "$Command is required. Run from an x64 Visual Studio developer shell."
      }
    }
  }
}

if (Test-Path $Build) { Remove-Item $Build -Recurse -Force }
if (Test-Path $Prefix) { Remove-Item $Prefix -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Build, $Stage, $Prefix | Out-Null

Push-Location $Build
try {
  $env:SOURCE_DATE_EPOCH = if ($env:SOURCE_DATE_EPOCH) { $env:SOURCE_DATE_EPOCH } else { '0' }
  & perl.exe (Join-Path $Source 'Configure') VC-WIN64A `
    "--prefix=$LogicalPrefix" --libdir=lib `
    '--openssldir=C:\ProgramData\mssql-native\ssl' `
    no-shared no-tests no-apps no-docs no-makedepend no-asm `
    no-legacy no-engine no-async no-comp no-dtls no-ssl3 `
    no-weak-ssl-ciphers no-ui-console /Brepro
  if ($LASTEXITCODE -ne 0) { throw "OpenSSL configure failed with exit code $LASTEXITCODE" }

  & nmake.exe build_libs
  if ($LASTEXITCODE -ne 0) { throw "OpenSSL build failed with exit code $LASTEXITCODE" }
  & nmake.exe install_dev "DESTDIR=$Stage"
  if ($LASTEXITCODE -ne 0) { throw "OpenSSL install_dev failed with exit code $LASTEXITCODE" }
} finally {
  Pop-Location
}

# windows-makefile.tmpl intentionally drops the drive component when DESTDIR
# is present, so C:\mssql-native\openssl is staged below DESTDIR at this path.
$Installed = Join-Path $Stage 'mssql-native\openssl'
if (-not (Test-Path (Join-Path $Installed 'include\openssl\ssl.h'))) {
  throw "OpenSSL headers were not staged below $Installed"
}
foreach ($Library in @('libcrypto.lib', 'libssl.lib')) {
  if (-not (Test-Path (Join-Path $Installed "lib\$Library"))) {
    throw "$Library was not staged below $Installed"
  }
}

Copy-Item (Join-Path $Installed 'include') $Prefix -Recurse -Force
New-Item -ItemType Directory -Force -Path (Join-Path $Prefix 'lib') | Out-Null
Copy-Item (Join-Path $Installed 'lib\libcrypto.lib') (Join-Path $Prefix 'lib\libcrypto.lib') -Force
Copy-Item (Join-Path $Installed 'lib\libssl.lib') (Join-Path $Prefix 'lib\libssl.lib') -Force
Write-Host "OpenSSL $Version staged for Windows x64 at $Prefix (static, /MT)." -ForegroundColor Green
