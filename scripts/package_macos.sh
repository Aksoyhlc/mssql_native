#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:-$ROOT/dist/mssql_native_macos.zip}"
"$ROOT/scripts/build_darwin.sh"
APP="$(find "$ROOT/example/build/macos/Build/Products/Release" -maxdepth 1 -type d -name '*.app' | head -n 1)"
[[ -n "$APP" ]] || { echo "Release .app not found." >&2; exit 1; }
mkdir -p "$(dirname "$DESTINATION")"
rm -f "$DESTINATION"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DESTINATION"
echo "Created $DESTINATION"
