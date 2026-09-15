#!/usr/bin/env bash
# Builds example/ and asserts the native frameworks are embedded and signed
# in the resulting .app. Run once with --spm and once with --cocoapods: the
# iOS plugin ships both manifests; macOS uses Dart code assets under either.
#
# The unit tests cannot cover this. They pass explicit paths through
# MSSQL_NATIVE_BRIDGE / MSSQL_NATIVE_SYBDB and never exercise in-bundle
# resolution, so a built app is the only real proof.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER=""
PLATFORM=macos

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spm) MANAGER=spm ;;
    --cocoapods) MANAGER=cocoapods ;;
    --platform) shift; PLATFORM="${1:?Missing platform}" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$MANAGER" ]] || { echo "Pass --spm or --cocoapods." >&2; exit 2; }

if [[ "$MANAGER" == "spm" ]]; then
  flutter config --enable-swift-package-manager >/dev/null
else
  flutter config --no-enable-swift-package-manager >/dev/null
fi

# Xcode's DerivedData survives `flutter clean`, so a previous run under the
# other dependency manager can leave frameworks behind and make this check pass
# for the wrong reason.
rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/Runner-*

cd "$ROOT/example"
flutter clean >/dev/null

if [[ "$PLATFORM" == "ios" ]]; then
  # A simulator build, not a device one: no signing identity is needed and the
  # simulator slice is what a CI machine can actually produce.
  flutter build ios --debug --simulator
  APP="$ROOT/example/build/ios/iphonesimulator/Runner.app"
  FRAMEWORKS_DIR="$APP/Frameworks"
  WANT_SYBDB_DEP='@rpath/sybdb.framework/sybdb'
  BRIDGE_NAME=MssqlNativeBridge
else
  flutter build macos --debug
  APP="$ROOT/example/build/macos/Build/Products/Debug/mssql_native_example.app"
  FRAMEWORKS_DIR="$APP/Contents/Frameworks"
  WANT_SYBDB_DEP='@rpath/sybdb.framework/sybdb'
  BRIDGE_NAME=mssql_native
fi
[[ -d "$APP" ]] || { echo "FAIL: app was not produced at $APP" >&2; exit 1; }

STATUS=0
for name in "$BRIDGE_NAME" sybdb; do
  fw="$FRAMEWORKS_DIR/$name.framework"
  if [[ ! -f "$fw/$name" ]]; then
    echo "FAIL [$PLATFORM/$MANAGER]: $name.framework is not embedded in the app" >&2
    ls -la "$FRAMEWORKS_DIR" >&2 || true
    STATUS=1
    continue
  fi
  # Simulator builds are ad-hoc signed, so the signature check is meaningless
  # there; on macOS a bad signature would break the app at launch.
  if [[ "$PLATFORM" != "ios" ]] && ! codesign -v "$fw" 2>/dev/null; then
    echo "FAIL [$PLATFORM/$MANAGER]: $name.framework is not validly signed" >&2
    STATUS=1
    continue
  fi
  echo "ok [$PLATFORM/$MANAGER]: $name.framework embedded"
done

# The bridge must resolve its sibling framework, not a stale bare dylib.
bridge="$FRAMEWORKS_DIR/$BRIDGE_NAME.framework/$BRIDGE_NAME"
if [[ -f "$bridge" ]]; then
  if ! otool -L "$bridge" | grep -qF "$WANT_SYBDB_DEP"; then
    echo "FAIL [$PLATFORM/$MANAGER]: embedded bridge does not link $WANT_SYBDB_DEP" >&2
    otool -L "$bridge" >&2
    STATUS=1
  fi
fi

# Nothing should ship the pre-migration bare dylibs any more.
if ls "$FRAMEWORKS_DIR" | grep -q 'libmssql_native\.dylib\|libsybdb\.dylib'; then
  echo "FAIL [$PLATFORM/$MANAGER]: the app still embeds pre-migration bare dylibs" >&2
  ls "$FRAMEWORKS_DIR" >&2
  STATUS=1
fi

[[ $STATUS -eq 0 ]] && echo "$PLATFORM app verified under $MANAGER."
exit $STATUS
