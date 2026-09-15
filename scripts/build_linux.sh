#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/freetds_source.sh
source "$ROOT/scripts/freetds_source.sh"
SOURCE="$(freetds_source "$ROOT")"
BUILD_ROOT="$ROOT/.native-build/linux"
FREETDS_BUILD="$BUILD_ROOT/freetds"
FREETDS_PREFIX="$ROOT/linux/vendor/freetds"
BRIDGE_BUILD="$BUILD_ROOT/bridge"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_FLUTTER=1
# TLS capability is compiled in by default from the pinned static OpenSSL
# source. Connection encryption remains opt-in and defaults to plaintext in
# the Dart API.
WITH_OPENSSL=1
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-flutter) BUILD_FLUTTER=0 ;;
    --with-openssl) WITH_OPENSSL=1 ;;
    --without-openssl) WITH_OPENSSL=0 ;;
    --clean) CLEAN=1 ;;
    --debug) CONFIGURATION=Debug ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ "$(uname -s)" == "Linux" ]] || { echo "This script must run on Linux." >&2; exit 1; }
[[ -f "$SOURCE/configure" ]] || { echo "FreeTDS source not found: $SOURCE" >&2; exit 1; }
command -v cmake >/dev/null || { echo "cmake is required." >&2; exit 1; }
command -v make >/dev/null || { echo "make is required." >&2; exit 1; }

# A fresh git checkout resets file mtimes, which can make `make` think the
# autotools inputs changed and try to regenerate them with a specific
# aclocal/automake version that is not installed. Pin the timestamps in
# dependency order so the shipped configure / Makefile.in / config.h.in are
# treated as up to date and no maintainer-mode rebuild is triggered.
find "$SOURCE" \( -name 'configure.ac' -o -name 'Makefile.am' -o \( -name '*.m4' ! -name 'aclocal.m4' \) \) -exec touch -t 202001010000 {} + 2>/dev/null || true
find "$SOURCE" -name 'aclocal.m4' -exec touch -t 202001020000 {} + 2>/dev/null || true
find "$SOURCE" \( -name 'configure' -o -name 'config.h.in' -o -name 'Makefile.in' \) -exec touch -t 202001030000 {} + 2>/dev/null || true

if [[ $CLEAN -eq 1 ]]; then
  rm -rf "$BUILD_ROOT" "$FREETDS_PREFIX"
fi
mkdir -p "$FREETDS_BUILD" "$FREETDS_PREFIX"

# libiconv is left enabled (autotools default) so FreeTDS links the system iconv
# (part of glibc) and can convert every single-byte code page — CHAR/VARCHAR
# columns with non-Latin1 collations such as Turkish_CI_AS (CP1254). Without it
# the built-in trivial converter only covers ASCII/ISO-8859-1/UTF-8/UCS-2/CP1252
# and silently mangles e.g. İ/Ş/Ğ into Ý/Þ/Ð.
CONFIGURE_ARGS=(
  "--prefix=$FREETDS_PREFIX"
  "--sysconfdir=/etc"
  --enable-shared
  --disable-static
  --disable-odbc
  --disable-apps
  --disable-server
  --disable-pool
  --enable-msdblib
)
PKG_ENV=(env)
if [[ $WITH_OPENSSL -eq 1 ]]; then
  command -v pkg-config >/dev/null \
    || { echo "pkg-config is required for --with-openssl." >&2; exit 1; }
  OPENSSL_PREFIX="$BUILD_ROOT/openssl-prefix"
  "$ROOT/scripts/build_openssl_linux.sh" --prefix "$OPENSSL_PREFIX"
  CONFIGURE_ARGS+=("--with-openssl=$OPENSSL_PREFIX")
  # PKG_CONFIG_LIBDIR replaces pkg-config's search path rather than extending
  # it, which is what keeps the build off the distribution's OpenSSL. Without
  # it FreeTDS finds the system one and links it dynamically, and libsybdb.so
  # ends up with a hard DT_NEEDED on libssl.so.3.
  # lib64 on x86_64, lib elsewhere; the OpenSSL build records which.
  OPENSSL_LIBDIR="$(cat "$OPENSSL_PREFIX/.libdir")"
  PKG_ENV+=("PKG_CONFIG_LIBDIR=$OPENSSL_PREFIX/$OPENSSL_LIBDIR/pkgconfig")
else
  CONFIGURE_ARGS+=(--without-openssl)
fi

pushd "$FREETDS_BUILD" >/dev/null
# The extracted sources live in .sources, outside .native-build, so mapping the
# repository root is enough: every __FILE__ becomes "./.sources/...", which
# carries no build-directory name - the release audit rejects those. The map
# also keeps a maintainer's home directory out of the shipped library.
"${PKG_ENV[@]}" "$SOURCE/configure" "${CONFIGURE_ARGS[@]}" \
  CFLAGS="-O2 -fPIC -ffile-prefix-map=$ROOT=. -fdebug-prefix-map=$ROOT=."
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
# sysconfdir is overridden for the install only. The compiled-in value
# stays /etc (see --sysconfdir at configure), which is what a shipped
# libsybdb should name; without this override `make install` would try
# to write /etc/freetds.conf on the build machine and fail on
# permissions.
make install sysconfdir="$FREETDS_PREFIX/etc"
popd >/dev/null

[[ -f "$FREETDS_PREFIX/include/sybdb.h" ]] || { echo "sybdb.h was not staged." >&2; exit 1; }
SYBDB_LIB="$(find "$FREETDS_PREFIX/lib" -maxdepth 1 -type f -name 'libsybdb.so*' | sort | head -n 1)"
[[ -n "$SYBDB_LIB" ]] || { echo "libsybdb.so was not built." >&2; exit 1; }
ln -sf "$(basename "$SYBDB_LIB")" "$FREETDS_PREFIX/lib/libsybdb.so"

cmake -S "$ROOT/native" -B "$BRIDGE_BUILD" \
  -DCMAKE_BUILD_TYPE="$CONFIGURATION" \
  -DCMAKE_C_FLAGS="-g0 -ffile-prefix-map=$ROOT=. -fdebug-prefix-map=$ROOT=." \
  -DMSSQL_NATIVE_HAS_TLS="$WITH_OPENSSL" \
  -DFREETDS_INCLUDE_DIR="$FREETDS_PREFIX/include" \
  -DFREETDS_LIBRARY="$FREETDS_PREFIX/lib/libsybdb.so"
cmake --build "$BRIDGE_BUILD" --config "$CONFIGURATION" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"

if [[ $WITH_OPENSSL -eq 1 ]]; then
  # A build that quietly lost OpenSSL would connect happily and never encrypt,
  # which is the failure worth refusing rather than reporting.
  grep -q '^#define HAVE_OPENSSL 1' "$FREETDS_BUILD/include/config.h" \
    || { echo "OpenSSL was requested but not detected; refusing to ship a build that cannot encrypt." >&2; exit 1; }

  # A dynamically linked OpenSSL would fail to load on a system without
  # libssl.so.3, which is worse than having no TLS, so static linking is
  # checked rather than assumed.
  if readelf -d "$SYBDB_LIB" 2>/dev/null | grep -qE 'NEEDED.*lib(ssl|crypto)'; then
    echo "libsybdb links OpenSSL dynamically; it must be static." >&2
    readelf -d "$SYBDB_LIB" | grep NEEDED >&2
    exit 1
  fi
  echo "TLS is enabled (OpenSSL, statically linked)."
  printf 'SIZE libsybdb %10s bytes\n' "$(stat -c%s "$SYBDB_LIB")"
else
  echo "TLS is disabled. Rebuild with --with-openssl when encrypted SQL Server connections are required."
fi

# The handler ships built, so that a consumer of the package needs no C
# toolchain: the Dart build hook stages this file instead of compiling
# native/src/handlers.c on the user's machine, exactly as the Apple and Android
# builds do with their own prebuilt binaries.
BRIDGE_LIB="$(find "$BRIDGE_BUILD" -maxdepth 2 -type f -name 'libmssql_native.so' | head -n 1)"
[[ -n "$BRIDGE_LIB" ]] || { echo "libmssql_native.so was not built." >&2; exit 1; }
mkdir -p "$ROOT/linux/lib"
install -m 755 "$BRIDGE_LIB" "$ROOT/linux/lib/libmssql_native.so"
strip --strip-unneeded "$ROOT/linux/lib/libmssql_native.so" 2>/dev/null || true
# The staged FreeTDS is called libsybdb.so.5 next to the handler, and the
# handler finds it through $ORIGIN. Both have to be true or the package loads
# on the maintainer's machine and nowhere else.
readelf -d "$ROOT/linux/lib/libmssql_native.so" | grep -q 'NEEDED.*libsybdb.so.5' \
  || { echo "The handler does not depend on libsybdb.so.5." >&2; exit 1; }
readelf -d "$ROOT/linux/lib/libmssql_native.so" | grep -qE 'R(UN)?PATH.*\$ORIGIN' \
  || { echo "The handler has no \$ORIGIN runpath." >&2; exit 1; }
printf 'SIZE libmssql_native %10s bytes\n' "$(stat -c%s "$ROOT/linux/lib/libmssql_native.so")"

# Flutter rebuilds the handler separately; carry the actual FreeTDS capability
# with the staged library instead of letting that build fall back to OFF.
printf '# Generated alongside the staged FreeTDS library; keep with its binaries.\nset(MSSQL_NATIVE_HAS_TLS %s)\n' \
  "$([[ $WITH_OPENSSL -eq 1 ]] && echo ON || echo OFF)" \
  > "$FREETDS_PREFIX/freetds_features.cmake"

if [[ $BUILD_FLUTTER -eq 1 ]]; then
  command -v flutter >/dev/null || { echo "Flutter is not installed; native libraries were built successfully. Use --no-flutter to suppress this check." >&2; exit 1; }
  pushd "$ROOT" >/dev/null
  flutter pub get
  popd >/dev/null
  if [[ ! -f "$ROOT/example/linux/CMakeLists.txt" ]]; then
    pushd "$ROOT/example" >/dev/null
    flutter create --platforms=linux .
    popd >/dev/null
  fi
  pushd "$ROOT/example" >/dev/null
  flutter pub get
  if [[ "$CONFIGURATION" == "Debug" ]]; then
    flutter build linux --debug
  else
    flutter build linux --release
  fi
  popd >/dev/null
fi

python3 "$ROOT/tool/verify_binary_paths.py" \
  "$ROOT/linux/lib" "$ROOT/linux/vendor/freetds/lib"
echo "Linux FreeTDS and handler library build completed."
