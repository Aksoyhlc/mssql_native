#!/usr/bin/env python3
"""Reject build-machine paths embedded in shipped native binaries."""

from __future__ import annotations

import re
import sys
from pathlib import Path


BINARY_NAMES = {"sybdb", "MssqlNativeBridge"}
BINARY_SUFFIXES = (".dll", ".dylib", ".so")
FORBIDDEN_MARKERS = (
    "/users/",
    "/home/",
    "/private/var/folders/",
    "/.native-build/",
    "/_work/",
    ":\\users\\",
    ":\\a\\",
    ":\\cfiles\\",
    "\\.native-build\\",
    "\\_work\\",
)
ASCII_STRING = re.compile(rb"[\x20-\x7e]{4,}")
UTF16_STRING = re.compile(rb"(?:[\x20-\x7e]\x00){4,}")
# A runpath that begins with $ORIGIN and then names an absolute path points at
# the machine that built the binary. The marker list below only catches that
# when the build directory happens to be a known one: a Linux build under /src
# passed this check, and libmssql_native.so shipped carrying
# "$ORIGIN:/src/linux/vendor/freetds/lib". $ORIGIN alone is the relocatable
# form every shipped library is supposed to have.
RPATH_ABSOLUTE = re.compile(r"\$ORIGIN:(?:/|[A-Za-z]:[\\/])", re.IGNORECASE)
SHIPPED_ROOTS = (
    "windows/bin",
    "windows/vendor/freetds/bin",
    "windows/redist",
    "linux/lib",
    "linux/vendor/freetds/lib",
    "darwin/lib",
    "darwin/mssql_native/Frameworks",
    "android/src/main/jniLibs",
)


def is_native_binary(path: Path) -> bool:
    name = path.name
    return (
        name in BINARY_NAMES
        or name.endswith(BINARY_SUFFIXES)
        or ".so." in name
    )


def printable_strings(data: bytes) -> set[str]:
    strings = {
        match.group().decode("ascii", errors="replace")
        for match in ASCII_STRING.finditer(data)
    }
    strings.update(
        match.group().decode("utf-16-le", errors="replace")
        for match in UTF16_STRING.finditer(data)
    )
    return strings


def forbidden_strings(data: bytes) -> list[str]:
    hits: set[str] = set()
    for value in printable_strings(data):
        folded = value.lower()
        if any(marker in folded for marker in FORBIDDEN_MARKERS):
            hits.add(value)
        elif RPATH_ABSOLUTE.search(value):
            hits.add(value)
    return sorted(hits)


def scan(root: Path) -> list[tuple[Path, str]]:
    failures: list[tuple[Path, str]] = []
    seen_targets: set[Path] = set()
    shipped = [root / relative for relative in SHIPPED_ROOTS]
    scan_roots = [path for path in shipped if path.exists()] or [root]
    paths = sorted(path for scan_root in scan_roots for path in scan_root.rglob("*"))
    for path in paths:
        if not path.is_file() or not is_native_binary(path):
            continue
        target = path.resolve()
        if target in seen_targets:
            continue
        seen_targets.add(target)
        for value in forbidden_strings(target.read_bytes()):
            failures.append((path, value))
    return failures


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: verify_binary_paths.py <package-root-or-payload> [...]", file=sys.stderr)
        return 2
    roots = [Path(value).resolve() for value in argv[1:]]
    for root in roots:
        if not root.is_dir():
            print(f"not a directory: {root}", file=sys.stderr)
            return 2

    failures = [(root, path, value) for root in roots for path, value in scan(root)]
    if failures:
        print("Forbidden build-machine paths found:", file=sys.stderr)
        for root, path, value in failures:
            print(f"  {path.relative_to(root)}: {value}", file=sys.stderr)
        return 1

    print("Native binaries contain no forbidden build-machine paths.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
