#!/usr/bin/env bash
# Builds FreeTDS and the C handler library for the Apple platforms and packages both as
# XCFrameworks under darwin/mssql_native/Frameworks.
#
# One script owns the final artifact because `xcodebuild -create-xcframework`
# takes every slice in a single invocation; two scripts would each overwrite the
# other's slices.
#
# iOS configure passes explicitly set both build and host triplets, so
# autoconf never attempts to launch an iOS executable on the macOS host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/freetds_source.sh
source "$ROOT/scripts/freetds_source.sh"
SOURCE="$(freetds_source "$ROOT")"
BUILD_ROOT="$ROOT/.native-build/darwin"
# Swift Package Manager forbids binaryTarget paths outside the package root and
# Flutter references the package through a symlink, so the shipped XCFrameworks
# must live inside darwin/mssql_native/. The podspec points at the same files.
FRAMEWORKS="$ROOT/darwin/mssql_native/Frameworks"
STAGE="$BUILD_ROOT/frameworks"
CONFIGURATION="${CONFIGURATION:-Release}"
PLATFORMS="macos,ios"
BUILD_FLUTTER=1
WITH_OPENSSL=1
CLEAN=0
STAGE_ONLY=0
BUILD_JOBS="${BUILD_JOBS:-$(getconf NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
# libtool's BSD probe uses sysctl, which can be unavailable in a sandbox.
# Use the host's accessible ARG_MAX value with libtool's 25% safety margin.
HOST_ARG_MAX="$(getconf ARG_MAX)"

MACOS_DEPLOYMENT_TARGET=10.15
IOS_DEPLOYMENT_TARGET=13.0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-flutter) BUILD_FLUTTER=0 ;;
    --with-openssl) WITH_OPENSSL=1 ;;
    --without-openssl) WITH_OPENSSL=0 ;;
    --clean) CLEAN=1 ;;
    --stage-dylibs-only) STAGE_ONLY=1 ;;
    --debug) CONFIGURATION=Debug ;;
    --platforms) shift; PLATFORMS="${1:?Missing platform list}" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "This script must run on macOS." >&2; exit 1; }
[[ -f "$SOURCE/configure" ]] || { echo "FreeTDS source not found: $SOURCE" >&2; exit 1; }
command -v cmake >/dev/null || { echo "cmake is required." >&2; exit 1; }
command -v make >/dev/null || { echo "make is required." >&2; exit 1; }
if [[ $WITH_OPENSSL -eq 1 ]]; then
  # The only OpenSSL branch in FreeTDS's configure that works for a
  # cross-compiled target goes through pkg-config; see build_variant.
  command -v pkg-config >/dev/null \
    || { echo "pkg-config is required for --with-openssl." >&2; exit 1; }
fi
command -v install_name_tool >/dev/null || { echo "Xcode command-line tools are required." >&2; exit 1; }

# TLS capability is compiled in by default with OpenSSL statically linked into
# FreeTDS; connections still default to plaintext in the Dart API. No separate
# OpenSSL runtime installation is needed. iconv stays enabled:
# it links Apple's system libiconv, present on both macOS and iOS, so FreeTDS
# can convert every single-byte code page — CHAR/VARCHAR columns with
# non-Latin1 collations such as Turkish_CI_AS (CP1254). Without it, FreeTDS's
# built-in trivial converter only handles ASCII/ISO-8859-1/UTF-8/UCS-2/CP1252
# and silently mangles e.g. İ/Ş/Ğ into Ý/Þ/Ð.

# A fresh git checkout resets file mtimes, which can make `make` try to
# regenerate the autotools inputs with an aclocal/automake version that is not
# installed. Pin the timestamps in dependency order so the shipped
# configure / Makefile.in / config.h.in are treated as up to date.
find "$SOURCE" \( -name 'configure.ac' -o -name 'Makefile.am' -o \( -name '*.m4' ! -name 'aclocal.m4' \) \) -exec touch -t 202001010000 {} + 2>/dev/null || true
find "$SOURCE" -name 'aclocal.m4' -exec touch -t 202001020000 {} + 2>/dev/null || true
find "$SOURCE" \( -name 'configure' -o -name 'config.h.in' -o -name 'Makefile.in' \) -exec touch -t 202001030000 {} + 2>/dev/null || true

# Wrap a plain dylib in a real Apple framework bundle. Framework-type bundles
# are what SPM binaryTarget needs: Xcode embeds and code-signs them into the
# consuming app automatically, which it does NOT do for a library-type
# xcframework wrapping a bare dylib.
#
# macOS uses the versioned bundle layout; iOS bundles are flat, with Info.plist
# at the root and a MinimumOSVersion / CFBundleSupportedPlatforms pair.
make_framework() { # $1 = source dylib, $2 = name, $3 = style: macos|ios|iossim
  local src="$1" name="$2" style="$3"
  local fw="$STAGE/$style/$name.framework"
  local bundle_id="com.aksoyhlc.${name//_/-}"  # bundle ids cannot contain underscores
  local binary plist install_name
  rm -rf "$fw"

  if [[ "$style" == "macos" ]]; then
    mkdir -p "$fw/Versions/A/Resources"
    binary="$fw/Versions/A/$name"
    plist="$fw/Versions/A/Resources/Info.plist"
    install_name="@rpath/$name.framework/Versions/A/$name"
  else
    mkdir -p "$fw"
    binary="$fw/$name"
    plist="$fw/Info.plist"
    install_name="@rpath/$name.framework/$name"
  fi

  cp -f "$src" "$binary"
  chmod +w "$binary"

  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<dict>'
    echo "  <key>CFBundleDevelopmentRegion</key><string>en</string>"
    echo "  <key>CFBundleExecutable</key><string>$name</string>"
    echo "  <key>CFBundleIdentifier</key><string>$bundle_id</string>"
    echo "  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>"
    echo "  <key>CFBundleName</key><string>$name</string>"
    echo "  <key>CFBundlePackageType</key><string>FMWK</string>"
    echo "  <key>CFBundleShortVersionString</key><string>0.2.0</string>"
    echo "  <key>CFBundleVersion</key><string>0.2.0</string>"
    case "$style" in
      macos)
        echo "  <key>LSMinimumSystemVersion</key><string>$MACOS_DEPLOYMENT_TARGET</string>" ;;
      ios)
        echo "  <key>MinimumOSVersion</key><string>$IOS_DEPLOYMENT_TARGET</string>"
        echo "  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>" ;;
      iossim)
        echo "  <key>MinimumOSVersion</key><string>$IOS_DEPLOYMENT_TARGET</string>"
        echo "  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>" ;;
    esac
    echo '</dict>'
    echo '</plist>'
  } > "$plist"

  if [[ "$style" == "macos" ]]; then
    ln -sfn A "$fw/Versions/Current"
    ln -sfn "Versions/Current/$name" "$fw/$name"
    ln -sfn Versions/Current/Resources "$fw/Resources"
  fi

  install_name_tool -id "$install_name" "$binary"
}

# Build FreeTDS and the bridge for one SDK, and stage both frameworks.
# Each Apple SDK needs its own pass: iphoneos and iphonesimulator are separate
# sysroots, so the single multi-arch configure that serves macOS cannot cover
# them.
build_variant() { # $1 = style: macos|ios|iossim
  local style="$1" sdk archs min_flag host_arg sdkroot arch_flags prefix build
  case "$style" in
    macos)  sdk=macosx;          archs="arm64 x86_64"; host_arg=""
            min_flag="-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET" ;;
    ios)    sdk=iphoneos;        archs="arm64";        host_arg="--host=aarch64-apple-darwin"
            min_flag="-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET" ;;
    iossim) sdk=iphonesimulator; archs="arm64 x86_64"; host_arg="--host=x86_64-apple-darwin"
            min_flag="-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET" ;;
    *) echo "Unknown build style: $style" >&2; exit 2 ;;
  esac

  echo "=== building $style ($archs) ==="
  sdkroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  arch_flags=""
  for a in $archs; do arch_flags+=" -arch $a"; done
  prefix="$BUILD_ROOT/$style/freetds-prefix"
  build="$BUILD_ROOT/$style/freetds"
  rm -rf "$build"; mkdir -p "$build" "$prefix"

  # OpenSSL is built per SDK, statically, and handed to FreeTDS's configure.
  # Apple has no system OpenSSL to link against and no Secure Transport backend
  # in FreeTDS, so this is the only route to TLS here.
  local tls_args=(--without-openssl --without-gnutls)
  # --sysconfdir is compiled in as the freetds.conf location. Left alone it
  # becomes $prefix/etc, naming this build's staging directory inside every
  # shipped libsybdb. /etc is FreeTDS's own convention; the driver overrides
  # the path at run time regardless.
  local configure_args=("--prefix=$prefix" "--sysconfdir=/etc")
  if [[ -n "$host_arg" ]]; then
    configure_args+=("--build=$("$SOURCE/config.guess")" "$host_arg")
  fi
  # `env` with nothing added is a harmless prefix, and avoids expanding an
  # empty array under `set -u` on the bash 3.2 that ships with macOS.
  local pkg_env=(env)
  local ssl_prefix=
  if [[ $WITH_OPENSSL -eq 1 ]]; then
    ssl_prefix="$BUILD_ROOT/$style/openssl-prefix"
    "$ROOT/scripts/build_openssl_apple.sh" --style "$style" --prefix "$ssl_prefix" \
      --macos-min "$MACOS_DEPLOYMENT_TARGET" --ios-min "$IOS_DEPLOYMENT_TARGET"
    # pkg-config, pointed at nothing but our own prefix.
    #
    # Not --with-openssl alone: FreeTDS wraps its manual directory scan in
    # `if test "$cross_compiling" != "yes"` (configure:23682), so on iOS the
    # directory is never looked at and configure fails with "Cannot find
    # OpenSSL libraries" however correct the path is. pkg-config is the only
    # branch that works for a cross-compiled target.
    #
    # PKG_CONFIG_LIBDIR *replaces* the search path rather than extending it,
    # which is what stops FreeTDS finding Homebrew's OpenSSL - host-architecture
    # libraries that cannot link into a universal or cross build.
    tls_args=("--with-openssl=$ssl_prefix")
    pkg_env+=("PKG_CONFIG_LIBDIR=$ssl_prefix/lib/pkgconfig")
  fi

  # CFLAGS carries -ffile-prefix-map to keep the build machine out of the
  # artefact. FreeTDS compiles __FILE__ into its logging, so without it every
  # shipped libsybdb carries the absolute path of whoever built it, in
  # __TEXT,__cstring where no strip can reach it. Note that a comment cannot go
  # inside the backslash-continued list below: the lines are joined before
  # tokenising, so a '#' there swallows every argument that follows it.
  ( cd "$build" && "${pkg_env[@]}" "$SOURCE/configure" \
      "${configure_args[@]}" \
      --enable-shared \
      --disable-static \
      --disable-odbc \
      --disable-apps \
      --disable-server \
      --disable-pool \
      --enable-msdblib \
      "${tls_args[@]}" \
      CC="$(xcrun --sdk "$sdk" --find clang)" \
      lt_cv_sys_max_cmd_len="$((HOST_ARG_MAX / 4 * 3))" \
      CFLAGS="$arch_flags -isysroot $sdkroot $min_flag -O2 -ffile-prefix-map=$ROOT=. -fdebug-prefix-map=$ROOT=." \
      LDFLAGS="$arch_flags -isysroot $sdkroot $min_flag" ) || {
    # The invocation and the failing test, not the tail: config.log ends with
    # a list of #defines, which is never the reason.
    echo "=== configure failed for $style ===" >&2
    echo "--- ssl prefix ---" >&2
    ls -l "$ssl_prefix/include/openssl/ssl.h" "$ssl_prefix/lib" >&2 || true
    echo "--- config.log invocation ---" >&2
    head -n 20 "$build/config.log" >&2 || true
    echo "--- config.log around the OpenSSL test ---" >&2
    grep -n -B5 -A30 'SSL_read' "$build/config.log" >&2 || true
    exit 1
  }

  # Refuse to ship a build that silently corrupts CP1254 data. The reviewed
  # prior art disables iconv here; we do not.
  grep -q '^#define HAVE_ICONV 1' "$build/include/config.h" \
    || { echo "iconv was not detected for $style; refusing to continue." >&2; exit 1; }

  # Same reasoning: a build that silently lost OpenSSL connects happily and
  # never encrypts.
  if [[ $WITH_OPENSSL -eq 1 ]]; then
    grep -q '^#define HAVE_OPENSSL 1' "$build/include/config.h" \
      || { echo "OpenSSL was requested but not detected for $style." >&2; exit 1; }
  fi

  # Build only the libraries we ship and their prerequisites. The recursive
  # default also builds CT-Library and upstream unit-test helper libraries.
  make -C "$build/include" -j"$BUILD_JOBS" all
  for component in utils replacements tds dblib; do
    make -C "$build/src/$component" -j"$BUILD_JOBS" all-am
  done
  make -C "$build/include" install-includeHEADERS install-nodist_includeHEADERS
  make -C "$build/src/dblib" install-libLTLIBRARIES

  local sybdb_real bridge_build bridge_real
  sybdb_real="$(find "$prefix/lib" -maxdepth 1 -type f -name 'libsybdb*.dylib' | sort | head -n 1)"
  [[ -n "$sybdb_real" ]] || { echo "libsybdb was not built for $style." >&2; exit 1; }

  bridge_build="$BUILD_ROOT/$style/bridge"
  local cmake_args=(
    -S "$ROOT/native" -B "$bridge_build"
    -DCMAKE_BUILD_TYPE="$CONFIGURATION"
    -DCMAKE_C_FLAGS="-g0 -ffile-prefix-map=$ROOT=. -fdebug-prefix-map=$ROOT=."
    -DMSSQL_NATIVE_HAS_TLS="$WITH_OPENSSL"
    -DCMAKE_OSX_ARCHITECTURES="$(echo "$archs" | tr ' ' ';')"
    -DCMAKE_OSX_SYSROOT="$sdkroot"
    -DFREETDS_INCLUDE_DIR="$prefix/include"
    -DFREETDS_LIBRARY="$sybdb_real"
  )
  if [[ "$style" == "macos" ]]; then
    cmake_args+=(-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET")
  else
    cmake_args+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET")
  fi
  cmake "${cmake_args[@]}"
  cmake --build "$bridge_build" --config "$CONFIGURATION" -j"$BUILD_JOBS"

  bridge_real="$(find "$bridge_build" -type f -name 'libmssql_native.dylib' | head -n 1)"
  [[ -n "$bridge_real" ]] || { echo "the bridge was not built for $style." >&2; exit 1; }

  # The bridge framework is NOT called mssql_native: Flutter's macOS Podfile
  # uses use_frameworks!, so CocoaPods already builds a pod module framework by
  # that name and the two would collide on one output path.
  printf 'SIZE %-8s sybdb %10s bytes  archs: %s\n' \
    "$style" "$(stat -f%z "$sybdb_real")" "$(lipo -archs "$sybdb_real")"

  make_framework "$sybdb_real" sybdb "$style"
  make_framework "$bridge_real" MssqlNativeBridge "$style"

  local bridge_bin sybdb_dep rpath
  if [[ "$style" == "macos" ]]; then
    bridge_bin="$STAGE/$style/MssqlNativeBridge.framework/Versions/A/MssqlNativeBridge"
    sybdb_dep='@rpath/sybdb.framework/Versions/A/sybdb'
    # Embedded at Contents/Frameworks/X.framework/Versions/A/X, so three levels
    # up from the loader is Contents/Frameworks.
    rpath='@loader_path/../../..'
  else
    bridge_bin="$STAGE/$style/MssqlNativeBridge.framework/MssqlNativeBridge"
    sybdb_dep='@rpath/sybdb.framework/sybdb'
    # On iOS the embedded binary sits at MyApp.app/Frameworks/X.framework/X,
    # so one level up from the loader is Frameworks.
    rpath='@loader_path/..'
  fi

  while IFS= read -r dependency; do
    case "$dependency" in
      *libsybdb*.dylib) install_name_tool -change "$dependency" "$sybdb_dep" "$bridge_bin" ;;
    esac
  done < <(otool -L "$bridge_bin" | tail -n +2 | awk '{print $1}')

  # CMake may already have baked this rpath in via INSTALL_RPATH, and
  # install_name_tool treats a duplicate as a hard error rather than a no-op.
  if ! otool -l "$bridge_bin" | grep -A2 LC_RPATH | grep -qF "$rpath"; then
    install_name_tool -add_rpath "$rpath" "$bridge_bin"
  fi
}

STYLES=""
case ",$PLATFORMS," in *,macos,*) STYLES="$STYLES macos" ;; esac
case ",$PLATFORMS," in *,ios,*)   STYLES="$STYLES ios iossim" ;; esac
[[ -n "$STYLES" ]] || { echo "--platforms selected nothing to build." >&2; exit 2; }

if [[ $CLEAN -eq 1 ]]; then
  rm -rf "$BUILD_ROOT"
  # Only drop the XCFrameworks when every slice is about to be rebuilt;
  # otherwise a --platforms macos run would silently delete the iOS slices.
  case "$PLATFORMS" in *macos*ios*|*ios*macos*) rm -rf "$FRAMEWORKS" ;; esac
fi
mkdir -p "$STAGE" "$FRAMEWORKS"

# Ready-to-copy dylibs for the plain Dart path, one pair per architecture.
#
# These files already carry their install names, rpath and ad-hoc signature,
# so the build hook only has to copy one of them.
#
# Per architecture rather than universal because the Dart SDK rewrites the
# install names of macOS code assets itself and rejects a file with more than
# one architecture section ("Expected a single architecture section in otool
# output").
stage_dylibs() {
  local sybdb="$FRAMEWORKS/sybdb.xcframework/macos-arm64_x86_64/sybdb.framework/Versions/A/sybdb"
  local bridge="$FRAMEWORKS/MssqlNativeBridge.xcframework/macos-arm64_x86_64/MssqlNativeBridge.framework/Versions/A/MssqlNativeBridge"
  [[ -f "$sybdb" && -f "$bridge" ]] || { echo "The macOS frameworks are missing; build them first." >&2; exit 1; }

  echo "=== staged plain-Dart dylibs ==="
  local arch out
  for arch in arm64 x86_64; do
    out="$ROOT/darwin/lib/$([[ $arch == x86_64 ]] && echo x64 || echo arm64)"
    mkdir -p "$out"
    xcrun lipo "$sybdb" -thin "$arch" -output "$out/libsybdb.dylib"
    xcrun lipo "$bridge" -thin "$arch" -output "$out/libmssql_native.dylib"
    xcrun install_name_tool -id '@rpath/libsybdb.dylib' "$out/libsybdb.dylib"
    xcrun install_name_tool -id '@rpath/libmssql_native.dylib' \
      -change '@rpath/sybdb.framework/Versions/A/sybdb' '@rpath/libsybdb.dylib' \
      -add_rpath '@loader_path' "$out/libmssql_native.dylib"
    # Signed here, once, so that copying is all the consumer's build has to do.
    codesign --force --sign - "$out/libsybdb.dylib"
    codesign --force --sign - "$out/libmssql_native.dylib"

    otool -L "$out/libmssql_native.dylib" | grep -q '@rpath/libsybdb.dylib' \
      || { echo "The staged $arch handler does not reference @rpath/libsybdb.dylib." >&2; exit 1; }
    codesign --verify "$out/libmssql_native.dylib" \
      || { echo "The staged $arch handler is not signed." >&2; exit 1; }
    printf '%-6s %-22s %10s bytes  archs: %s\n' "$arch" libsybdb.dylib \
      "$(stat -f%z "$out/libsybdb.dylib")" "$(lipo -archs "$out/libsybdb.dylib")"
    printf '%-6s %-22s %10s bytes  archs: %s\n' "$arch" libmssql_native.dylib \
      "$(stat -f%z "$out/libmssql_native.dylib")" "$(lipo -archs "$out/libmssql_native.dylib")"
  done
}

if [[ $STAGE_ONLY -eq 1 ]]; then
  stage_dylibs
  exit 0
fi

for style in $STYLES; do build_variant "$style"; done

for name in sybdb MssqlNativeBridge; do
  args=()
  for style in $STYLES; do args+=(-framework "$STAGE/$style/$name.framework"); done
  rm -rf "$FRAMEWORKS/$name.xcframework"
  xcodebuild -create-xcframework "${args[@]}" -output "$FRAMEWORKS/$name.xcframework"
done

stage_dylibs

if [[ $BUILD_FLUTTER -eq 1 ]]; then
  command -v flutter >/dev/null || { echo "Flutter is not installed; native libraries were built successfully. Use --no-flutter to suppress this check." >&2; exit 1; }
  pushd "$ROOT" >/dev/null
  flutter pub get
  popd >/dev/null
  pushd "$ROOT/example" >/dev/null
  flutter pub get
  if [[ "$CONFIGURATION" == "Debug" ]]; then
    flutter build macos --debug
  else
    flutter build macos --release
  fi
  popd >/dev/null
fi

# The number that decides whether TLS is worth shipping here: what each slice
# costs an application.
echo "=== shipped framework sizes ==="
for style in $STYLES; do
  for name in sybdb MssqlNativeBridge; do
    bin="$(find "$STAGE/$style/$name.framework" -type f -name "$name" | head -n 1)"
    [[ -f "$bin" ]] || continue
    printf '%-8s %-20s %10s bytes  archs: %s\n' \
      "$style" "$name" "$(stat -f%z "$bin")" "$(lipo -archs "$bin")"
  done
done

python3 "$ROOT/tool/verify_binary_paths.py" \
  "$ROOT/darwin/lib" "$ROOT/darwin/mssql_native/Frameworks"

echo "Apple build completed for:$STYLES (TLS: $([[ $WITH_OPENSSL -eq 1 ]] && echo OpenSSL || echo disabled))"
if [[ $WITH_OPENSSL -eq 0 ]]; then
  echo "TLS is disabled. Rebuild with --with-openssl and a locally available OpenSSL toolchain when encryption is required."
fi
