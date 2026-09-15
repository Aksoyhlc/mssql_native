$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Vendor = Join-Path $Root 'windows\vendor\freetds'
$Required = @(
  (Join-Path $Vendor 'include\sybdb.h'),
  (Join-Path $Vendor 'include\tds_sysdep_public.h'),
  (Join-Path $Vendor 'lib\sybdb.lib'),
  (Join-Path $Vendor 'bin\sybdb.dll')
)
foreach ($Path in $Required) {
  if (-not (Test-Path $Path)) { throw "Missing required FreeTDS file: $Path" }
}
$Dlls = @(Get-ChildItem (Join-Path $Vendor 'bin') -Filter '*.dll')
if ($Dlls.Count -ne 1 -or $Dlls[0].Name -ne 'sybdb.dll') {
  throw "The release FreeTDS payload must contain only sybdb.dll; found: $($Dlls.Name -join ', ')"
}
# OpenSSL, win-iconv and the MSVC runtime must all be static. Import names
# appear verbatim in the PE, so reading bytes is enough and needs no toolchain.
$SybdbPath = Join-Path $Vendor 'bin\sybdb.dll'
$Bytes = [System.IO.File]::ReadAllBytes($SybdbPath)
$Ascii = [System.Text.Encoding]::ASCII.GetString($Bytes)
$Imported = @()
foreach ($Pattern in @(
  'libssl[-_0-9A-Za-z]*\.dll', 'libcrypto[-_0-9A-Za-z]*\.dll',
  'ssleay32\.dll', 'libeay32\.dll', 'iconv\.dll',
  'vcruntime[0-9_]*\.dll', 'msvcp[0-9_]*\.dll')) {
  if ($Ascii -match $Pattern) { $Imported += $Matches[0] }
}
if ($Imported.Count -gt 0) {
  throw "sybdb.dll has forbidden dynamic dependencies: $($Imported -join ', ')"
}
Write-Host 'sybdb.dll has no dynamic OpenSSL, iconv, or MSVC runtime dependency.' -ForegroundColor Green

Write-Host 'FreeTDS DB-Library headers/import/runtime files are present.' -ForegroundColor Green
Write-Host 'Runtime DLLs:'
$Dlls | ForEach-Object { Write-Host " - $($_.Name)" }
