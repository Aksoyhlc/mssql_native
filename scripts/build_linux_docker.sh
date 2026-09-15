#!/usr/bin/env bash
# Builds the Linux native binaries in a container, from any host with Docker.
#
# The container lets non-Linux hosts run the same Linux build and controls the
# glibc version linked into the shipped binaries.
set -euo pipefail

# Ubuntu 22.04 is used here. What a build links against sets the oldest
# distribution the result runs on, and building on 24.04 raised the floor from
# glibc 2.34 to 2.38 - which would have dropped Ubuntu 22.04, Debian 12 and
# RHEL 9 users the moment TLS was switched on.
IMAGE="${IMAGE:-ubuntu:22.04}"
ARGS=(--no-flutter --clean)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) shift; IMAGE="${1:?}" ;;
    --without-openssl) ARGS+=(--without-openssl) ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v docker >/dev/null || { echo "docker is required." >&2; exit 1; }

LOG="$ROOT/.native-build/linux-docker.log"
mkdir -p "$(dirname "$LOG")"
echo "=== building in $IMAGE (linux/amd64) ==="
echo "full output: $LOG"
if [[ "$(uname -m)" == "arm64" ]]; then
  echo "note: x86_64 is emulated on this host, so OpenSSL takes a while."
fi

# Root inside the container so packages can be installed, then the outputs are
# handed back to the invoking user - otherwise the build leaves root-owned files
# in the working tree that the host cannot clean up.
# Compiler output goes to the log, not the terminal: OpenSSL alone emits tens
# of thousands of lines, which buries the few that matter and makes a working
# build look like a hung one.
if ! docker run --rm \
  --platform linux/amd64 \
  -v "$ROOT:/src" \
  -w /src \
  -e "HOST_UID=$(id -u)" \
  -e "HOST_GID=$(id -g)" \
  "$IMAGE" bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq build-essential cmake pkg-config perl curl ca-certificates python3 >/dev/null
    echo "--- toolchain ---"
    # `|| true` on both: head closes the pipe after one line, the writer dies
    # of SIGPIPE, and with pipefail that aborted the whole build before it
    # started - the log ended at exactly this line and said nothing.
    gcc --version | head -1 || true
    ldd --version | head -1 || true
    ./scripts/build_linux.sh '"${ARGS[*]}"'
    echo "--- handing outputs back to the host user ---"
    chown -R "$HOST_UID:$HOST_GID" linux/vendor .native-build 2>/dev/null || true
  ' > "$LOG" 2>&1; then
  echo "the container build failed; last 40 lines:" >&2
  tail -n 40 "$LOG" >&2
  exit 1
fi

grep -E "^(TLS is|SIZE |gcc |ldd |Linux FreeTDS)" "$LOG" || true

SYBDB="$(readlink -f "$ROOT/linux/vendor/freetds/lib/libsybdb.so")"
echo
echo "=== result ==="
ls -l "$ROOT/linux/vendor/freetds/lib"
echo "--- dynamic dependencies ---"
docker run --rm -v "$ROOT:/src" -w /src "$IMAGE" bash -euo pipefail -c '
  export DEBIAN_FRONTEND=noninteractive
  command -v readelf >/dev/null || { apt-get update -qq; apt-get install -y -qq binutils >/dev/null; }
  readelf -d "$(readlink -f linux/vendor/freetds/lib/libsybdb.so)" | grep NEEDED'
echo "--- highest glibc symbol version required (the oldest distribution it runs on) ---"
strings -a "$SYBDB" | grep -oE "GLIBC_2\.[0-9]+" | sort -u -V | tail -3
