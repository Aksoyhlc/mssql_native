#!/usr/bin/env bash
# Resolve a pinned third-party source tree, downloading and verifying it.
#
# Every third-party dependency this package builds against is pinned by
# version and SHA-256, and each vendor directory carries the metadata that
# says where it comes from:
#
#   native/vendor/<name>/UPSTREAM.url     upstream release URL
#   native/vendor/<name>/UPSTREAM.sha256  "<sha256>  <archive filename>"
#
# The archive is taken from the vendor directory when one is committed there,
# then from the download cache, and only then fetched. libiconv ships its
# archive so Android builds work offline; FreeTDS and OpenSSL come straight
# from their own release pages and are checked against the pinned SHA-256.
#
# A checksum mismatch stops extraction before a substituted archive can enter
# the build.
#
# Usage:
#   # shellcheck source=scripts/fetch_source.sh
#   source "$ROOT/scripts/fetch_source.sh"
#   SOURCE="$(fetch_source "$ROOT" freetds)"

fetch_source() { # $1 = repository root, $2 = vendor directory name
  local root="$1" name="$2"
  local vendor="$root/native/vendor/$name"
  local url_file="$vendor/UPSTREAM.url"
  local sums="$vendor/UPSTREAM.sha256"
  # Not under .native-build: these paths reach the compiled binaries through
  # __FILE__, and a build script maps the repository root to ".". A source below
  # .native-build would leave "./.native-build/..." in the shipped library,
  # which the release audit rejects. The pathmap is not relied on.
  local downloads="$root/.sources/downloads"
  local sources="$root/.sources"

  local url archive_name expected
  if [[ ! -f "$url_file" ]]; then
    echo "Missing $url_file" >&2
    return 1
  fi
  if [[ ! -f "$sums" ]]; then
    echo "Missing $sums" >&2
    return 1
  fi
  url="$(grep -m1 -v '^[[:space:]]*$' "$url_file" | tr -d '[:space:]')"
  expected="$(awk 'NR==1 {print $1}' "$sums")"
  archive_name="$(awk 'NR==1 {print $2}' "$sums")"
  if [[ -z "$url" || -z "$expected" || -z "$archive_name" ]]; then
    echo "Could not read the URL and checksum for $name" >&2
    return 1
  fi

  local archive=""
  if [[ -f "$vendor/$archive_name" ]]; then
    archive="$vendor/$archive_name"
  elif [[ -f "$downloads/$archive_name" ]]; then
    archive="$downloads/$archive_name"
  else
    mkdir -p "$downloads"
    echo "Downloading $archive_name" >&2
    if ! curl -fsSL -o "$downloads/$archive_name" "$url"; then
      echo "Download failed: $url" >&2
      echo "Place the archive at $vendor/$archive_name to build offline." >&2
      return 1
    fi
    archive="$downloads/$archive_name"
  fi

  local actual
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$archive" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch for $name:" >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    echo "  file     $archive" >&2
    echo "Delete that file and re-run to fetch a fresh copy." >&2
    return 1
  fi

  # freetds-1.5.16.tar.bz2 -> freetds-1.5.16
  local dir_name="${archive_name%%.tar.*}"
  local extracted="$sources/$dir_name"
  local stamp="$sources/$dir_name.archive-sha256"
  local have=""
  [[ -f "$stamp" ]] && have="$(cat "$stamp")"

  if [[ ! -d "$extracted" || "$have" != "$expected" ]]; then
    rm -rf "$extracted" "$stamp"
    mkdir -p "$sources"
    # stdout goes to stderr: this function's stdout is its return value, and a
    # stray line from tar would be captured with the path.
    tar -xf "$archive" -C "$sources" >&2
    if [[ ! -d "$extracted" ]]; then
      echo "Extracted archive did not produce $extracted" >&2
      return 1
    fi
    printf '%s\n' "$expected" > "$stamp"
  fi

  echo "$extracted"
}
