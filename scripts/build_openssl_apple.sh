#!/usr/bin/env bash
# Builds a static OpenSSL for one Apple SDK, so FreeTDS can be linked with TLS.
#
# Static on purpose: it is linked into sybdb.framework, so the linker keeps only
# the objects FreeTDS actually reaches. A dynamic OpenSSL would mean shipping
# two more frameworks and every byte of them.
#
# Trimmed, but NOT with no-deprecated: FreeTDS's sec_negotiate_openssl.h calls
# RSA_public_encrypt, which OpenSSL 3 deprecated. Removing it breaks the build.
set -euo pipefail

STYLE=""
PREFIX=""
MACOS_MIN=10.15
IOS_MIN=13.0
BUILD_JOBS="${BUILD_JOBS:-$(getconf NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --style) shift; STYLE="${1:?}" ;;
    --prefix) shift; PREFIX="${1:?}" ;;
    --macos-min) shift; MACOS_MIN="${1:?}" ;;
    --ios-min) shift; IOS_MIN="${1:?}" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$STYLE" && -n "$PREFIX" ]] || { echo "--style and --prefix are required." >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$ROOT/.native-build/openssl/$STYLE"
LOGICAL_PREFIX=/opt/mssql-native/openssl

# Pinned, like FreeTDS is. Asking the GitHub API for the newest 3.5 patch was
# the first version of this and it returned 403 from a CI runner - unauthenticated
# rate limiting - which is a poor reason for a build to fail, and a moving
# dependency is a poor thing to ship anyway. Bump this deliberately.
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.8}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
echo "=== OpenSSL $OPENSSL_VERSION for $STYLE ==="

# The pinned OpenSSL archive is downloaded on first use or read from the local
# cache. Its SHA-256 is checked before the source is used.
# shellcheck source=scripts/openssl_source.sh
source "$ROOT/scripts/openssl_source.sh"
SOURCE="$(openssl_source "$ROOT")"

case "$STYLE" in
  macos)  ARCHS="arm64 x86_64"; SDK=macosx ;;
  ios)    ARCHS="arm64";        SDK=iphoneos ;;
  iossim) ARCHS="arm64 x86_64"; SDK=iphonesimulator ;;
  *) echo "Unknown style: $STYLE" >&2; exit 2 ;;
esac

# no-async: OpenSSL's async engine needs setcontext, which iOS does not provide.
# The rest is surface FreeTDS never calls.
# --openssldir is compiled in as OPENSSLDIR, the directory libcrypto reads a
# CA bundle from and therefore what MssqlTlsTrust.system() depends on. The
# default is $prefix/ssl, which would name this build's staging directory.
# /etc/ssl is the platform convention and where macOS keeps cert.pem.
COMMON_OPTS=(
  "--prefix=$LOGICAL_PREFIX"
  --libdir=lib
  --openssldir=/etc/ssl
  no-shared no-tests no-apps no-docs
  no-legacy no-engine no-async no-comp
  no-dtls no-ssl3 no-weak-ssl-ciphers no-ui-console
)

rm -rf "$BUILD_ROOT" "$PREFIX"
mkdir -p "$BUILD_ROOT" "$PREFIX/lib"

for arch in $ARCHS; do
  echo "--- $STYLE/$arch ---"
  work="$BUILD_ROOT/$arch"
  stage="$work/stage"
  rm -rf "$work"; mkdir -p "$work" "$stage"
  ( cd "$work"
    case "$STYLE" in
      macos)
        target="darwin64-$arch-cc"
        "$SOURCE/Configure" "$target" "${COMMON_OPTS[@]}" \
          "-mmacosx-version-min=$MACOS_MIN"
        ;;
      ios)
        export CROSS_TOP="$(xcode-select -p)/Platforms/iPhoneOS.platform/Developer"
        export CROSS_SDK=iPhoneOS.sdk
        "$SOURCE/Configure" ios64-xcrun "${COMMON_OPTS[@]}" \
          "-mios-version-min=$IOS_MIN"
        ;;
      iossim)
        # The darwin64-*-cc targets, not iossimulator-xcrun. OpenSSL's
        # Configure reads any argument that does not start with "-" as a target
        # name, so the "arm64" of "-arch arm64" became a second target and it
        # refused with "target already defined - iossimulator-xcrun (offending
        # arg: arm64)". These targets carry their own -arch, and pointing
        # -isysroot at the simulator SDK is what retargets them; the
        # -mios-simulator-version-min is what makes the Mach-O declare platform
        # 7, which verify_darwin.sh checks.
        # Not `local`: this loop is top-level script, not a function.
        sim_target=""
        case "$arch" in
          arm64)  sim_target=darwin64-arm64-cc ;;
          x86_64) sim_target=darwin64-x86_64-cc ;;
          *) echo "Unsupported simulator arch: $arch" >&2; exit 2 ;;
        esac
        "$SOURCE/Configure" "$sim_target" "${COMMON_OPTS[@]}" \
          "-isysroot" "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
          "-mios-simulator-version-min=$IOS_MIN"
        ;;
    esac
    make -j"$BUILD_JOBS" build_libs
    make install_dev DESTDIR="$stage" >/dev/null )
done

# One fat archive per library, matching how the FreeTDS slices are built.
FIRST_ARCH="$(echo "$ARCHS" | awk '{print $1}')"
cp -R "$BUILD_ROOT/$FIRST_ARCH/stage$LOGICAL_PREFIX/include" "$PREFIX/"
for lib in libcrypto libssl; do
  inputs=()
  for arch in $ARCHS; do
    inputs+=("$BUILD_ROOT/$arch/stage$LOGICAL_PREFIX/lib/$lib.a")
  done
  if [[ ${#inputs[@]} -eq 1 ]]; then
    cp "${inputs[0]}" "$PREFIX/lib/$lib.a"
  else
    lipo -create "${inputs[@]}" -output "$PREFIX/lib/$lib.a"
  fi
  printf '%-12s %10s bytes  archs: %s\n' "$lib.a" \
    "$(stat -f%z "$PREFIX/lib/$lib.a")" "$(lipo -archs "$PREFIX/lib/$lib.a")"
done

# A pkg-config file, because it is the only route FreeTDS leaves open for a
# cross-compiled target: its manual directory scan is wrapped in
# `if test "$cross_compiling" != "yes"` (configure:23682), so for iOS the
# --with-openssl path is never even looked at.
#
# Written by hand rather than copied from OpenSSL's own: theirs carries
# Libs.private with -ldl, which does not exist on Apple, and points at the
# per-architecture prefix rather than this merged one.
mkdir -p "$PREFIX/lib/pkgconfig"
for module in openssl libssl libcrypto; do
  cat > "$PREFIX/lib/pkgconfig/$module.pc" <<PC
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: $module
Description: Static OpenSSL $OPENSSL_VERSION for mssql_native
Version: $OPENSSL_VERSION
Cflags: -I\${includedir}
Libs: -L\${libdir} -lssl -lcrypto
PC
done

echo "OpenSSL $OPENSSL_VERSION staged for $STYLE at $PREFIX"
