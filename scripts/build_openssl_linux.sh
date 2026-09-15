#!/usr/bin/env bash
# Builds a static, position-independent OpenSSL for Linux.
#
# Linking OpenSSL statically keeps libsybdb.so from depending on a system
# libssl.so.3. The driver can load on older distributions and slim containers
# that do not provide OpenSSL 3. The static payload adds about five megabytes.
#
# Built from source rather than using the distribution's libssl.a, because
# Debian and Ubuntu have historically shipped a libcrypto.a compiled without
# -fPIC, which cannot be linked into a shared library at all.
set -euo pipefail

PREFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) shift; PREFIX="${1:?}" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$PREFIX" ]] || { echo "--prefix is required." >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.native-build/openssl/linux"
LOGICAL_PREFIX=/opt/mssql-native/openssl
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.8}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
echo "=== OpenSSL $OPENSSL_VERSION for linux ==="

# The pinned OpenSSL archive is downloaded on first use or read from the local
# cache. Its SHA-256 is checked before the source is used.
# shellcheck source=scripts/openssl_source.sh
source "$ROOT/scripts/openssl_source.sh"
SOURCE="$(openssl_source "$ROOT")"

case "$(uname -m)" in
  x86_64)  TARGET=linux-x86_64 ;;
  aarch64) TARGET=linux-aarch64 ;;
  *) echo "Unsupported machine: $(uname -m)" >&2; exit 2 ;;
esac

# Same trimming as the Apple build, and for the same reason NOT no-deprecated:
# FreeTDS calls RSA_public_encrypt, which OpenSSL 3 deprecated.
rm -rf "$BUILD" "$PREFIX"
mkdir -p "$BUILD/stage" "$PREFIX"
( cd "$BUILD" && "$SOURCE/Configure" "$TARGET" \
    "--prefix=$LOGICAL_PREFIX" --libdir=lib \
    --openssldir=/etc/ssl \
    no-shared no-tests no-apps no-docs \
    no-legacy no-engine no-async no-comp \
    no-dtls no-ssl3 no-weak-ssl-ciphers no-ui-console \
    -fPIC
  make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" build_libs
  make install_dev DESTDIR="$BUILD/stage" >/dev/null )

INSTALLED="$BUILD/stage$LOGICAL_PREFIX"
cp -R "$INSTALLED/include" "$PREFIX/"

# OpenSSL installs to lib64 on Linux x86_64 and to lib elsewhere, so the
# directory is discovered rather than assumed - guessing "lib" made the build
# fail with "libcrypto.a was not installed" after compiling all of it, and
# would have put the wrong libdir in the pkg-config file below.
LIBDIR=""
for candidate in lib64 lib; do
  if [[ -f "$INSTALLED/$candidate/libcrypto.a" ]]; then
    LIBDIR="$candidate"
    mkdir -p "$PREFIX/$candidate"
    cp "$INSTALLED/$candidate/libcrypto.a" "$INSTALLED/$candidate/libssl.a" \
      "$PREFIX/$candidate/"
    break
  fi
done
[[ -n "$LIBDIR" ]] || { echo "libcrypto.a was not installed under $PREFIX." >&2; exit 1; }
echo "OpenSSL installed its libraries in $LIBDIR"

# A pkg-config file of our own, and PKG_CONFIG_LIBDIR pointed at it, is how the
# build is kept off the distribution's OpenSSL: pkg-config would otherwise
# answer with the system one and FreeTDS would link that dynamically.
#
# Written by hand rather than copied from OpenSSL's, whose Libs.private names
# libraries that are unnecessary on glibc 2.34 and later, where libdl and
# libpthread are part of libc.
mkdir -p "$PREFIX/$LIBDIR/pkgconfig"
for module in openssl libssl libcrypto; do
  cat > "$PREFIX/$LIBDIR/pkgconfig/$module.pc" <<PC
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/$LIBDIR
includedir=\${prefix}/include

Name: $module
Description: Static OpenSSL $OPENSSL_VERSION for mssql_native
Version: $OPENSSL_VERSION
Cflags: -I\${includedir}
Libs: -L\${libdir} -lssl -lcrypto
PC
done

for lib in libcrypto libssl; do
  path="$PREFIX/$LIBDIR/$lib.a"
  [[ -f "$path" ]] || { echo "$lib.a was not installed." >&2; exit 1; }
  printf '%-12s %10s bytes\n' "$lib.a" "$(stat -c%s "$path")"
done
echo "OpenSSL $OPENSSL_VERSION staged for linux at $PREFIX (libdir $LIBDIR)"
# Consumed by build_linux.sh, which needs PKG_CONFIG_LIBDIR to point here.
echo "$LIBDIR" > "$PREFIX/.libdir"
