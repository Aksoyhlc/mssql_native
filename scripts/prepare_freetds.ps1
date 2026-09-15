param([Parameter(Mandatory=$true)] [string]$From)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Vendor = Join-Path $Root 'windows\vendor\freetds'
$Features = Join-Path $From 'freetds_features.cmake'
if (-not (Test-Path $Features)) {
  throw 'The input package must include freetds_features.cmake with its matching FreeTDS binaries.'
}
$Mappings = @{
  (Join-Path $From 'include') = (Join-Path $Vendor 'include')
  (Join-Path $From 'lib')     = (Join-Path $Vendor 'lib')
  (Join-Path $From 'bin')     = (Join-Path $Vendor 'bin')
}
foreach ($Source in $Mappings.Keys) {
  if (-not (Test-Path $Source)) { throw "Source directory missing: $Source" }
  Copy-Item (Join-Path $Source '*') $Mappings[$Source] -Recurse -Force
}
Copy-Item $Features (Join-Path $Vendor 'freetds_features.cmake') -Force
& "$PSScriptRoot\verify_freetds.ps1"
