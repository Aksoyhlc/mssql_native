#!/usr/bin/env bash
# Builds a static OpenSSL for one Android ABI.
#
# Android has no system OpenSSL. Linking it statically avoids shipping separate
# libssl.so and libcrypto.so files for each ABI.
#
# Android is the easiest of OpenSSL's cross-compile targets - it takes the NDK
# directly through ANDROID_NDK_ROOT and an android-* target - which is a
# pleasant change from the iOS pass.
set -euo pipefail

ABI=""
PREFIX=""
API="${ANDROID_API:-24}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --abi) shift; ABI="${1:?}" ;;
    --prefix) shift; PREFIX="${1:?}" ;;
    --api) shift; API="${1:?}" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$ABI" && -n "$PREFIX" ]] || { echo "--abi and --prefix are required." >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.native-build/android/$ABI/openssl"
LOGICAL_PREFIX=/opt/mssql-native/openssl
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.8}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

source "$ROOT/scripts/android_ndk_env.sh"
ndk_env_for_abi "$ABI" "$API"

case "$ABI" in
  arm64-v8a) TARGET=android-arm64 ;;
  x86_64)    TARGET=android-x86_64 ;;
  *) echo "Unsupported ABI: $ABI" >&2; exit 2 ;;
esac

# The pinned OpenSSL archive is downloaded on first use or read from the local
# cache. Its SHA-256 is checked before the source is used.
# shellcheck source=scripts/openssl_source.sh
source "$ROOT/scripts/openssl_source.sh"
SOURCE="$(openssl_source "$ROOT")"

echo "=== OpenSSL $OPENSSL_VERSION for $ABI ($TARGET, API $API) ==="

# OpenSSL finds the NDK compilers on PATH; ANDROID_NDK_ROOT is exported by
# ndk_env_for_abi. NOT no-deprecated: FreeTDS calls RSA_public_encrypt, which
# OpenSSL 3 deprecated.
export PATH="$(dirname "$NDK_CC"):$PATH"

rm -rf "$BUILD" "$PREFIX"
mkdir -p "$BUILD/stage" "$PREFIX"
( cd "$BUILD" && "$SOURCE/Configure" "$TARGET" \
    "--prefix=$LOGICAL_PREFIX" --libdir=lib \
    --openssldir=/system/etc/security \
    no-shared no-tests no-apps no-docs \
    no-legacy no-engine no-async no-comp \
    no-dtls no-ssl3 no-weak-ssl-ciphers no-ui-console \
    "-D__ANDROID_API__=$API" >/dev/null
  make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)" build_libs >/dev/null
  make install_dev DESTDIR="$BUILD/stage" >/dev/null )

INSTALLED="$BUILD/stage$LOGICAL_PREFIX"
cp -R "$INSTALLED/include" "$PREFIX/"

# lib64 on some targets, lib on others; discovered rather than assumed, because
# guessing cost a whole build once already on Linux.
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

# Our own .pc files, and PKG_CONFIG_LIBDIR pointed at them, are the only route
# FreeTDS leaves open to a cross-compiled target: its manual --with-openssl
# directory scan is wrapped in `if test "$cross_compiling" != "yes"`
# (configure:23682), and every Android build is a cross-compile.
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
echo "$LIBDIR" > "$PREFIX/.libdir"

for lib in libcrypto libssl; do
  printf '%-12s %10s bytes\n' "$lib.a" \
    "$(wc -c < "$PREFIX/$LIBDIR/$lib.a" | tr -d ' ')"
done
echo "OpenSSL $OPENSSL_VERSION staged for $ABI at $PREFIX (libdir $LIBDIR)"
