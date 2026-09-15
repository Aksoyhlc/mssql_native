#!/usr/bin/env bash
# Shared NDK toolchain setup, sourced by the Android build scripts.
#
# Kept in one place because three separate autotools/CMake builds - libiconv,
# OpenSSL and FreeTDS - all need the same compiler, triple and sysroot, and
# getting one of them subtly different is how a build produces objects that
# will not link together.

# The prebuilt toolchain directory for this build host, or nothing.
#
# darwin-arm64 first, then darwin-x86_64, which runs under Rosetta: newer NDKs
# ship a native Apple Silicon toolchain and older ones do not.
ndk_host_bin() { # $1 = ndk root
  local candidate
  for candidate in darwin-arm64 darwin-x86_64 linux-x86_64; do
    if [[ -x "$1/toolchains/llvm/prebuilt/$candidate/bin/clang" ]]; then
      echo "$1/toolchains/llvm/prebuilt/$candidate/bin"
      return 0
    fi
  done
  return 1
}

# Locates a *usable* NDK, preferring an explicit ANDROID_NDK_ROOT.
#
# Newest-that-works rather than simply newest: an interrupted SDK download
# leaves a version directory with no toolchain in it, and picking that produces
# "no such compiler" from whichever build happens to run first rather than a
# sentence about the NDK.
ndk_root() {
  if [[ -n "${ANDROID_NDK_ROOT:-}" ]]; then
    ndk_host_bin "$ANDROID_NDK_ROOT" >/dev/null \
      || { echo "ANDROID_NDK_ROOT has no usable toolchain: $ANDROID_NDK_ROOT" >&2; return 1; }
    echo "$ANDROID_NDK_ROOT"; return
  fi
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  local version skipped=""
  for version in $(ls -1 "$sdk/ndk" 2>/dev/null | sort -V -r); do
    if ndk_host_bin "$sdk/ndk/$version" >/dev/null; then
      [[ -z "$skipped" ]] || echo "Skipped NDK(s) with no toolchain:$skipped" >&2
      echo "$sdk/ndk/$version"; return 0
    fi
    skipped="$skipped $version"
  done
  echo "No usable NDK under $sdk/ndk; set ANDROID_NDK_ROOT." >&2
  return 1
}

# Sets NDK_TRIPLE, NDK_CC, NDK_AR, NDK_RANLIB, NDK_CFLAGS and NDK_LDFLAGS.
ndk_env_for_abi() { # $1 = abi, $2 = api level
  local abi="$1" api="$2" root bin
  root="$(ndk_root)" || return 1
  bin="$(ndk_host_bin "$root")" || return 1

  case "$abi" in
    # The clang target triple and the autotools --host triple differ for arm:
    # armv7 is "armv7a-linux-androideabi<api>" to clang and
    # "arm-linux-androideabi" to configure. Only 64-bit is built today, but the
    # distinction is why these are two separate variables.
    arm64-v8a) NDK_TRIPLE=aarch64-linux-android; NDK_CLANG="aarch64-linux-android$api" ;;
    x86_64)    NDK_TRIPLE=x86_64-linux-android;  NDK_CLANG="x86_64-linux-android$api" ;;
    *) echo "Unsupported ABI: $abi" >&2; return 1 ;;
  esac

  NDK_CC="$bin/${NDK_CLANG}-clang"
  [[ -x "$NDK_CC" ]] || { echo "No compiler for $abi at API $api: $NDK_CC" >&2; return 1; }
  # llvm-ar and llvm-ranlib, not the per-triple wrappers: the NDK dropped those
  # and only the unprefixed tools are present in current releases.
  NDK_AR="$bin/llvm-ar"
  NDK_RANLIB="$bin/llvm-ranlib"
  # -ffile-prefix-map keeps the build machine out of the artefact. FreeTDS
  # compiles __FILE__ into its logging, and the CMake handler build records
  # its own source and build directories, so without this every shipped .so
  # carries the absolute path of whoever built it.
  # $PWD would depend on where this file was sourced from; resolve the package
  # root from this script's own location instead.
  local package_root
  package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  NDK_CFLAGS="-O2 -fPIC -ffile-prefix-map=$package_root=. -fdebug-prefix-map=$package_root=. -ffile-prefix-map=$root=ndk -fdebug-prefix-map=$root=ndk"
  NDK_LDFLAGS=""
  export NDK_TRIPLE NDK_CC NDK_AR NDK_RANLIB NDK_CFLAGS NDK_LDFLAGS NDK_CLANG
  export ANDROID_NDK_ROOT="$root"
}
