#!/usr/bin/env bash
# Builds FreeTDS, its dependencies and the handler library for Android.
#
# Two ABIs: arm64-v8a for devices, x86_64 for the emulator. No 32-bit ARM -
# Play has required 64-bit since 2019 and serves arm64-v8a to anything capable
# of it, so armeabi-v7a would only reach hardware that is not a target while
# adding a third to what every consumer of this package downloads.
#
# The output lands in android/src/main/jniLibs/<abi>/, which Gradle bundles
# into the APK with no setup step for the application developer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/freetds_source.sh
source "$ROOT/scripts/freetds_source.sh"
SOURCE="$(freetds_source "$ROOT")"
BUILD_ROOT="$ROOT/.native-build/android"
JNI_LIBS="$ROOT/android/src/main/jniLibs"
API="${ANDROID_API:-24}"
ABIS="arm64-v8a x86_64"
WITH_OPENSSL=1
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --abis) shift; ABIS="${1:?}" ;;
    --api) shift; API="${1:?}" ;;
    --without-openssl) WITH_OPENSSL=0 ;;
    --clean) CLEAN=1 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v pkg-config >/dev/null || { echo "pkg-config is required." >&2; exit 1; }
[[ -f "$SOURCE/configure" ]] || { echo "FreeTDS source not found: $SOURCE" >&2; exit 1; }
source "$ROOT/scripts/android_ndk_env.sh"

# A fresh checkout resets mtimes, which can make make think the autotools
# inputs changed and try to regenerate them with a version that is not here.
find "$SOURCE" \( -name 'configure.ac' -o -name 'Makefile.am' -o \( -name '*.m4' ! -name 'aclocal.m4' \) \) -exec touch -t 202001010000 {} + 2>/dev/null || true
find "$SOURCE" -name 'aclocal.m4' -exec touch -t 202001020000 {} + 2>/dev/null || true
find "$SOURCE" \( -name 'configure' -o -name 'config.h.in' -o -name 'Makefile.in' \) -exec touch -t 202001030000 {} + 2>/dev/null || true

[[ $CLEAN -eq 1 ]] && rm -rf "$BUILD_ROOT"

build_abi() { # $1 = abi
  local abi="$1"
  ndk_env_for_abi "$abi" "$API"

  local prefix="$BUILD_ROOT/$abi/freetds-prefix"
  local build="$BUILD_ROOT/$abi/freetds"
  local iconv_prefix="$BUILD_ROOT/$abi/libiconv-prefix"
  local ssl_prefix="$BUILD_ROOT/$abi/openssl-prefix"

  echo "=== FreeTDS for $abi (API $API) ==="

  [[ -f "$iconv_prefix/lib/libiconv.a" ]] \
    || "$ROOT/scripts/build_libiconv_android.sh" --abi "$abi" --prefix "$iconv_prefix" --api "$API"

  local tls_args=(--without-openssl --without-gnutls)
  local pkg_env=(env)
  if [[ $WITH_OPENSSL -eq 1 ]]; then
    [[ -f "$ssl_prefix/.libdir" ]] \
      || "$ROOT/scripts/build_openssl_android.sh" --abi "$abi" --prefix "$ssl_prefix" --api "$API"
    tls_args=("--with-openssl=$ssl_prefix")
    pkg_env+=("PKG_CONFIG_LIBDIR=$ssl_prefix/$(cat "$ssl_prefix/.libdir")/pkgconfig")
  fi

  rm -rf "$build" "$prefix"; mkdir -p "$build" "$prefix"
  ( cd "$build" && "${pkg_env[@]}" "$SOURCE/configure" \
      --host="$NDK_TRIPLE" \
      "--prefix=$prefix" \
      --sysconfdir=/etc \
      --enable-shared --disable-static \
      --disable-odbc --disable-apps --disable-server --disable-pool \
      --enable-msdblib \
      "--with-libiconv-prefix=$iconv_prefix" \
      "${tls_args[@]}" \
      CC="$NDK_CC" AR="$NDK_AR" RANLIB="$NDK_RANLIB" \
      CFLAGS="$NDK_CFLAGS" LDFLAGS="$NDK_LDFLAGS" ) || {
    echo "=== configure failed for $abi ===" >&2
    head -n 20 "$build/config.log" >&2 || true
    grep -n -B5 -A25 'iconv_open\|SSL_read' "$build/config.log" >&2 || true
    exit 1
  }

  # The whole reason Android needs libiconv: without it FreeTDS falls back to a
  # converter that knows ASCII, Latin-1, UTF-8, UCS-2 and CP1252 and silently
  # mangles Turkish. A build that lost it is refused rather than shipped.
  grep -q '^#define HAVE_ICONV 1' "$build/include/config.h" \
    || { echo "iconv was not detected for $abi; refusing to continue." >&2; exit 1; }
  if [[ $WITH_OPENSSL -eq 1 ]]; then
    grep -q '^#define HAVE_OPENSSL 1' "$build/include/config.h" \
      || { echo "OpenSSL was requested but not detected for $abi." >&2; exit 1; }
  fi

  make -C "$build" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)"
  # sysconfdir is overridden for the install only. The compiled-in value
  # stays /etc (see --sysconfdir at configure), which is what a shipped
  # libsybdb should name; without this override `make install` would try
  # to write /etc/freetds.conf on the build machine and fail on
  # permissions.
  make -C "$build" install sysconfdir="$prefix/etc"

  local sybdb
  sybdb="$(find "$prefix/lib" -maxdepth 1 -type f -name 'libsybdb.so*' | sort | head -n 1)"
  [[ -n "$sybdb" ]] || { echo "libsybdb.so was not built for $abi." >&2; exit 1; }

  # Android's loader has no soname versioning: the APK holds lib/<abi>/NAME.so
  # and dlopen takes the bare name. A libsybdb.so.5 would simply not be found.
  mkdir -p "$JNI_LIBS/$abi"
  cp "$sybdb" "$JNI_LIBS/$abi/libsybdb.so"

  local handler_build="$BUILD_ROOT/$abi/handlers"
  rm -rf "$handler_build"
  cmake -S "$ROOT/native" -B "$handler_build" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$API" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-g0 -ffile-prefix-map=$ROOT=. -fdebug-prefix-map=$ROOT=. -ffile-prefix-map=$ANDROID_NDK_ROOT=ndk -fdebug-prefix-map=$ANDROID_NDK_ROOT=ndk" \
    -DMSSQL_NATIVE_HAS_TLS="$WITH_OPENSSL" \
    -DFREETDS_INCLUDE_DIR="$prefix/include" \
    -DFREETDS_LIBRARY="$JNI_LIBS/$abi/libsybdb.so" >/dev/null
  cmake --build "$handler_build" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)" >/dev/null
  cp "$(find "$handler_build" -name 'libmssql_native.so' | head -n 1)" "$JNI_LIBS/$abi/"

  echo "--- $abi payload ---"
  ls -l "$JNI_LIBS/$abi"
}

for abi in $ABIS; do build_abi "$abi"; done

python3 "$ROOT/tool/verify_binary_paths.py" "$JNI_LIBS"
echo "=== Android build completed for: $ABIS (TLS: $([[ $WITH_OPENSSL -eq 1 ]] && echo OpenSSL || echo disabled)) ==="
