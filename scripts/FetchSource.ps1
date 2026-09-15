# Resolve a pinned third-party source tree, downloading and verifying it.
#
# The Windows counterpart of scripts/fetch_source.sh, reading the same
# per-vendor metadata:
#
#   native\vendor\<name>\UPSTREAM.url     upstream release URL
#   native\vendor\<name>\UPSTREAM.sha256  "<sha256>  <archive filename>"
#
# The archive is taken from the vendor directory when one is committed there,
# then from the download cache, and only then fetched. A SHA-256 mismatch stops
# extraction before the archive can enter a build.
#
function Get-SourceTree {
  param(
    [Parameter(Mandatory = $true)] [string]$Root,
    [Parameter(Mandatory = $true)] [string]$Name
  )

  $Vendor = Join-Path $Root "native\vendor\$Name"
  $UrlFile = Join-Path $Vendor 'UPSTREAM.url'
  $SumsFile = Join-Path $Vendor 'UPSTREAM.sha256'
  # Deliberately not under .native-build: these paths end up in the compiled
  # binaries via __FILE__, and the build maps the repository root to ".",
  # so a source below .native-build would leave "./.native-build/..." in the
  # shipped library - which the release audit rejects on every platform.
  # Windows settled it: its /pathmap did not apply at all and the absolute
  # path was embedded verbatim. From here the result is clean either way.
  $Downloads = Join-Path $Root '.sources\downloads'
  $Sources = Join-Path $Root '.sources'

  if (-not (Test-Path $UrlFile)) { throw "Missing $UrlFile" }
  if (-not (Test-Path $SumsFile)) { throw "Missing $SumsFile" }

  $Expected = $null
  $ArchiveName = $null
  foreach ($Line in Get-Content $UrlFile) {
    if ($Line.Trim()) { $Url = $Line.Trim(); break }
  }
  $Fields = ((Get-Content $SumsFile -First 1).Trim() -split '\s+')
  $Expected = $Fields[0]
  if ($Fields.Count -ge 2) { $ArchiveName = $Fields[1] }
  if (-not $Url -or -not $Expected -or -not $ArchiveName) {
    throw "Could not read the URL and checksum for $Name"
  }

  $VendorArchive = Join-Path $Vendor $ArchiveName
  $Archive = Join-Path $Downloads $ArchiveName
  if (Test-Path $VendorArchive) {
    $Archive = $VendorArchive
  } elseif (-not (Test-Path $Archive)) {
    New-Item -ItemType Directory -Force -Path $Downloads | Out-Null
    Write-Host "Downloading $ArchiveName"
    # Out-Null matters: anything written to this function's output stream would
    # be captured by the caller along with the path it returns.
    & curl.exe -fL --retry 3 -o $Archive $Url | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Download failed: $Url`nPlace the archive at $VendorArchive to build offline."
    }
  }

  $Actual = (Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($Actual -ne $Expected) {
    throw "Checksum mismatch for $Name`n  expected $Expected`n  actual   $Actual`n  file     $Archive`nDelete that file and re-run to fetch a fresh copy."
  }

  # freetds-1.5.16.tar.bz2 -> freetds-1.5.16
  $DirName = $ArchiveName -replace '\.tar\..*$', ''
  $Extracted = Join-Path $Sources $DirName
  $Stamp = "$Extracted.archive-sha256"
  $Have = if (Test-Path $Stamp) { (Get-Content $Stamp -First 1).Trim() } else { '' }

  if (-not (Test-Path $Extracted) -or $Have -ne $Expected) {
    if (Test-Path $Extracted) { Remove-Item $Extracted -Recurse -Force }
    if (Test-Path $Stamp) { Remove-Item $Stamp -Force }
    New-Item -ItemType Directory -Force -Path $Sources | Out-Null

    # Extracted with CMake, not tar.exe.
    #
    # Which tar a Windows runner resolves is not fixed - it depends on PATH,
    # and both msvc-dev-cmd and Git prepend directories - and on the hosted
    # runner `tar.exe -xf` on this .tar.bz2 sat for twelve minutes and never
    # finished; the step was cancelled still waiting. CMake is already required
    # by every build script and carries its own libarchive, so it extracts the
    # same way everywhere and is known to handle bzip2 - the same archive
    # unpacks in under a second.
    Push-Location $Sources
    try {
      & cmake -E tar xf $Archive | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "Extraction failed: $Archive" }
    } finally {
      Pop-Location
    }
    if (-not (Test-Path $Extracted)) { throw "Extracted archive did not produce $Extracted" }
    Set-Content -Path $Stamp -Value $Expected -Encoding ascii
  }

  return $Extracted
}
