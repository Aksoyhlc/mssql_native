#!/usr/bin/env bash
# Structural checks on the shipped Apple XCFrameworks. Run after
# scripts/build_darwin.sh; also run in CI so packaging cannot silently regress.
#
# Only inspects packaged files; it does not build or execute the driver.
#
# The bridge framework is deliberately NOT named mssql_native: Flutter's macOS
# Podfile uses use_frameworks!, so CocoaPods already builds a pod module
# framework called mssql_native.framework, and two producers writing the same
# path under Contents/Frameworks is a duplicate-output error.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORKS="$ROOT/darwin/mssql_native/Frameworks"
STATUS=0

fail() { echo "FAIL: $*" >&2; STATUS=1; }
ok()   { echo "ok: $*"; }

SLICES="macos-arm64_x86_64 ios-arm64 ios-arm64_x86_64-simulator"

# macOS frameworks are versioned bundles; iOS frameworks are flat.
slice_binary() { # $1 = framework name, $2 = slice
  case "$2" in
    macos-*) echo "$FRAMEWORKS/$1.xcframework/$2/$1.framework/Versions/A/$1" ;;
    *)       echo "$FRAMEWORKS/$1.xcframework/$2/$1.framework/$1" ;;
  esac
}

slice_plist() { # $1 = framework name, $2 = slice
  case "$2" in
    macos-*) echo "$FRAMEWORKS/$1.xcframework/$2/$1.framework/Versions/A/Resources/Info.plist" ;;
    *)       echo "$FRAMEWORKS/$1.xcframework/$2/$1.framework/Info.plist" ;;
  esac
}

expected_archs() { # $1 = slice
  case "$1" in
    macos-arm64_x86_64)         echo "arm64 x86_64" ;;
    ios-arm64)                  echo "arm64" ;;
    ios-arm64_x86_64-simulator) echo "arm64 x86_64" ;;
  esac
}

# LC_BUILD_VERSION reports the platform as a number, not a name:
# 1 = macOS, 2 = iOS, 7 = iOS Simulator.
expected_platform() { # $1 = slice
  case "$1" in
    macos-*)     echo "1" ;;
    *-simulator) echo "7" ;;
    ios-*)       echo "2" ;;
  esac
}

for name in sybdb MssqlNativeBridge; do
  xcf="$FRAMEWORKS/$name.xcframework"
  if [[ ! -d "$xcf" ]]; then
    fail "missing xcframework: $xcf"
    continue
  fi
  [[ -f "$xcf/Info.plist" ]] || fail "$name.xcframework has no Info.plist"

  for slice in $SLICES; do
    bin="$(slice_binary "$name" "$slice")"
    if [[ ! -f "$bin" ]]; then
      fail "$name is missing slice $slice"
      continue
    fi

    archs="$(lipo -archs "$bin" 2>/dev/null)"
    want_archs="$(expected_archs "$slice")"
    for arch in $want_archs; do
      grep -qw "$arch" <<<"$archs" || fail "$name/$slice lacks arch $arch (has: $archs)"
    done
    for arch in $archs; do
      grep -qw "$arch" <<<"$want_archs" || fail "$name/$slice has unexpected arch $arch"
    done

    # A device slice carrying simulator code is an App Store rejection, and the
    # reverse would fail to run. Check what the binary itself declares.
    want_platform="$(expected_platform "$slice")"
    got_platform="$(otool -l "$bin" 2>/dev/null \
      | awk '/LC_BUILD_VERSION/{f=1} f && $1=="platform"{print $2; exit}')"
    [[ "$got_platform" == "$want_platform" ]] \
      || fail "$name/$slice declares platform '$got_platform', expected '$want_platform'"

    # iconv is what keeps Turkish CP1254 data intact. The reviewed prior art
    # dropped it on iOS; losing it corrupts data with no other symptom.
    if [[ "$name" == "sybdb" ]]; then
      otool -L "$bin" 2>/dev/null | grep -q 'libiconv' \
        || fail "$name/$slice does not link libiconv - CP1254 data would be corrupted"
    fi

    plist="$(slice_plist "$name" "$slice")"
    if [[ -f "$plist" ]]; then
      bundleid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || echo '')"
      case "$bundleid" in
        *_*) fail "$name/$slice CFBundleIdentifier '$bundleid' contains an underscore" ;;
        '')  fail "$name/$slice has no CFBundleIdentifier" ;;
      esac
      if [[ "$slice" == ios-* ]]; then
        minos="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$plist" 2>/dev/null || echo '')"
        [[ "$minos" == "13.0" ]] \
          || fail "$name/$slice MinimumOSVersion is '$minos', expected 13.0"
      fi
    else
      fail "$name/$slice has no Info.plist at $plist"
    fi

    ok "$name/$slice: [$archs] platform $got_platform"
  done
done

# Every sybdb slice must link iconv. FreeTDS converts the server's code page -
# CP1254 for a Turkish collation - through iconv, and a build that quietly lost
# it passes every structural check above and then corrupts Turkish text at
# runtime.
for slice in $SLICES; do
  bin="$(slice_binary sybdb "$slice")"
  [[ -f "$bin" ]] || continue
  otool -L "$bin" 2>/dev/null | grep -qi 'libiconv' \
    || fail "sybdb/$slice does not link iconv; Turkish code pages would be corrupted"
  ok "sybdb/$slice links iconv"
done

# The handler library must resolve its sibling framework once both are
# embedded. The
# relative depth differs: on macOS the loader sits in X.framework/Versions/A/,
# on iOS directly in X.framework/.
for slice in $SLICES; do
  bridge="$(slice_binary MssqlNativeBridge "$slice")"
  [[ -f "$bridge" ]] || continue
  case "$slice" in
    macos-*) want_rpath='@loader_path/../../..'; want_dep='@rpath/sybdb.framework/Versions/A/sybdb' ;;
    *)       want_rpath='@loader_path/..';       want_dep='@rpath/sybdb.framework/sybdb' ;;
  esac
  otool -L "$bridge" 2>/dev/null | grep -qF "$want_dep" \
    || fail "bridge/$slice does not link $want_dep"
  otool -l "$bridge" 2>/dev/null | grep -A2 LC_RPATH | grep -qF "$want_rpath" \
    || fail "bridge/$slice is missing rpath $want_rpath"
  ok "bridge/$slice resolves sybdb"
done

# The pre-migration layout must be gone, so nothing can consume it by accident.
[[ -e "$ROOT/macos" ]] && fail "legacy macos/ still exists; it must be removed"

if ! python3 "$ROOT/tool/verify_binary_paths.py" \
  "$ROOT/darwin/lib" "$ROOT/darwin/mssql_native/Frameworks"; then
  fail "Apple payload contains a producer-machine or CI build path"
else
  ok "Apple payload contains no producer-machine or CI build path"
fi

if [[ $STATUS -eq 0 ]]; then
  echo "Apple packaging verified."
fi
exit $STATUS
