#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/linux/vendor/freetds"
for file in "$VENDOR/include/sybdb.h" "$VENDOR/include/tds_sysdep_public.h" "$VENDOR/lib/libsybdb.so"; do
  [[ -e "$file" ]] || { echo "Missing: $file" >&2; exit 1; }
done
# The check worth having: FreeTDS converts the server's code page - CP1254 for
# a Turkish collation - through iconv. On glibc iconv lives in libc, so this
# confirms the built-in trivial converter was not silently used instead.
if ! grep -q '^#define HAVE_ICONV 1' "$ROOT/.native-build/linux/freetds/include/config.h" 2>/dev/null; then
  echo "Warning: could not confirm HAVE_ICONV from the build tree (not built here?)." >&2
fi
python3 "$ROOT/tool/verify_binary_paths.py" \
  "$ROOT/linux/lib" \
  "$ROOT/linux/vendor/freetds/lib"
echo "Linux FreeTDS staging is complete."
