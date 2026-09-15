#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:-$ROOT/dist/mssql_native_linux_x64.zip}"
"$ROOT/scripts/build_linux.sh"
BUNDLE="$ROOT/example/build/linux/x64/release/bundle"
[[ -d "$BUNDLE" ]] || { echo "Release bundle not found: $BUNDLE" >&2; exit 1; }
mkdir -p "$(dirname "$DESTINATION")"
rm -f "$DESTINATION"
(cd "$BUNDLE" && zip -qr "$DESTINATION" .)
echo "Created $DESTINATION"
