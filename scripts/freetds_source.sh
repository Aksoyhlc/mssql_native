#!/usr/bin/env bash
# Resolve the FreeTDS source tree a build should compile, applying this
# package's modification to it.
#
# The repository does not carry a FreeTDS copy. The build fetches the pinned
# upstream release - verified against native/vendor/freetds/UPSTREAM.sha256 -
# and then overwrites one file with the version under
# native/vendor/freetds/patches/, which is the only change this package makes
# to FreeTDS:
#
#   patches/src/dblib/bcp.c -> src/dblib/bcp.c
#
# The checksum identifies the release being built. The one changed file is
# kept here as a whole file, making it easy to review. It carries the change
# notice required by GNU Library GPL section 2(b).
#
# FreeTDS-derived build trees are discarded whenever the source path, the
# upstream release or the patch changes: they record the path they were
# configured against, and a rebuilt file whose timestamp is not newer than its
# object would be skipped. OpenSSL-derived trees and downloaded archives are
# kept.
#
# Usage:
#   # shellcheck source=scripts/freetds_source.sh
#   source "$ROOT/scripts/freetds_source.sh"
#   SOURCE="$(freetds_source "$ROOT")"

freetds_source() { # $1 = repository root; echoes the source tree path
  local root="$1"
  local vendor="$root/native/vendor/freetds"
  local patch="$vendor/patches/src/dblib/bcp.c"
  local native="$root/.native-build"

  if [[ ! -f "$patch" ]]; then
    echo "FreeTDS patch not found: $patch" >&2
    return 1
  fi

  # shellcheck source=scripts/fetch_source.sh
  source "$root/scripts/fetch_source.sh"
  local extracted
  if ! extracted="$(fetch_source "$root" freetds)"; then
    return 1
  fi

  local upstream patch_sha fingerprint
  upstream="$(awk 'NR==1 {print $1}' "$vendor/UPSTREAM.sha256")"
  if command -v sha256sum >/dev/null 2>&1; then
    patch_sha="$(sha256sum "$patch" | awk '{print $1}')"
  else
    patch_sha="$(shasum -a 256 "$patch" | awk '{print $1}')"
  fi
  fingerprint="$extracted $upstream $patch_sha"

  local marker="$native/freetds-source.fingerprint"
  if [[ ! -f "$marker" || "$(cat "$marker")" != "$fingerprint" ]]; then
    # Everything FreeTDS-derived goes; the extracted sources and downloads are
    # no longer in here (they live in .sources), and the OpenSSL prefix is kept
    # because it does not depend on FreeTDS and rebuilding it costs minutes.
    if [[ -d "$native" ]]; then
      find "$native" -mindepth 1 -maxdepth 1 \
        ! -name 'openssl*' -exec rm -rf {} + 2>/dev/null || true
    fi
    mkdir -p "$native"
    printf '%s\n' "$fingerprint" > "$marker"
  fi

  cp -f "$patch" "$extracted/src/dblib/bcp.c"

  echo "$extracted"
}
