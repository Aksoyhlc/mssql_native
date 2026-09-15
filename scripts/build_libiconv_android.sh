#!/usr/bin/env bash
# Builds a static GNU libiconv for one Android ABI.
#
# Android needs its own iconv. Bionic gained iconv_open in API 28 and supports
# only UTF and ASCII variants - its own header says so:
#
#   "Android supports the utf8, ascii, usascii, utf16be, utf16le, utf32be,
#    utf32le, and wchart encodings for both source and destination."
#   (NDK sysroot/usr/include/iconv.h)
#
# Bionic cannot convert CP1254, so VARCHAR data under a Turkish collation
# would be corrupted without a separate libiconv build.
#
# Bundling libiconv also removes the API 28 floor, because bionic's iconv is
# never called. The minimum stays Flutter's own.
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
BUILD="$ROOT/.native-build/android/$ABI/libiconv"
LIBICONV_VERSION="${LIBICONV_VERSION:-1.18}"

source "$ROOT/scripts/android_ndk_env.sh"
ndk_env_for_abi "$ABI" "$API"

# libiconv comes from GNU's own release directory, and its archive ships with
# the package (native/vendor/libiconv) so Android builds work offline. Either
# way the checksum is enforced before anything is compiled from it.
# shellcheck source=scripts/fetch_source.sh
source "$ROOT/scripts/fetch_source.sh"
SOURCE="$(fetch_source "$ROOT" libiconv)"

echo "=== libiconv $LIBICONV_VERSION for $ABI (API $API) ==="

rm -rf "$BUILD" "$PREFIX"
mkdir -p "$BUILD"
( cd "$BUILD" && "$SOURCE/configure" \
    --host="$NDK_TRIPLE" \
    "--prefix=$PREFIX" \
    --enable-static --disable-shared \
    --disable-rpath \
    CC="$NDK_CC" AR="$NDK_AR" RANLIB="$NDK_RANLIB" \
    CFLAGS="$NDK_CFLAGS -fPIC" \
    LDFLAGS="$NDK_LDFLAGS" >/dev/null
  make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)" >/dev/null
  make install >/dev/null )

[[ -f "$PREFIX/lib/libiconv.a" ]] \
  || { echo "libiconv.a was not installed under $PREFIX." >&2; exit 1; }
printf 'libiconv.a   %10s bytes\n' "$(wc -c < "$PREFIX/lib/libiconv.a" | tr -d ' ')"
echo "libiconv $LIBICONV_VERSION staged for $ABI at $PREFIX"
