#!/usr/bin/env bash
# Resolve the OpenSSL source tree a build should compile.
#
# This helper fetches the pinned OpenSSL release and checks it against
# native/vendor/openssl/UPSTREAM.sha256. OpenSSL is not patched here. Its
# 53 MB archive is downloaded or read from the local cache.
#
# Usage:
#   # shellcheck source=scripts/openssl_source.sh
#   source "$ROOT/scripts/openssl_source.sh"
#   SOURCE="$(openssl_source "$ROOT")"

openssl_source() { # $1 = repository root; echoes the source tree path
  local root="$1"
  # shellcheck source=scripts/fetch_source.sh
  source "$root/scripts/fetch_source.sh"
  fetch_source "$root" openssl
}
