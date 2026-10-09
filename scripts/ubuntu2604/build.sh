#!/usr/bin/env bash
# Build Snapmaker Orca for Ubuntu 26.04 inside a container (no host sudo needed).
# The repo is mounted at the same absolute path so CMake caches stay valid on the host.
# Compiles go through ccache, kept on the host in SNAP_ORCA_CCACHE_DIR
# (default ~/.cache/snap-orca-ccache), so rebuilds after a commit or a clean only recompile what
# changed. Runs at low CPU priority.
# Usage: scripts/ubuntu2604/build.sh [build_linux.sh flags]   (default: -dsr)
#        scripts/ubuntu2604/build.sh -- COMMAND...             (any command in the same environment)
set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")
ROOT=$(readlink -f "${HERE}/../..")
IMAGE=snap-orca-build:26.04
CCACHE_HOST_DIR=${SNAP_ORCA_CCACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/snap-orca-ccache}

docker image inspect "${IMAGE}" >/dev/null 2>&1 || docker build -t "${IMAGE}" "${HERE}"
mkdir -p "${CCACHE_HOST_DIR}"
[[ $# -eq 0 ]] && set -- -dsr
if [[ $1 == -- ]]; then
    shift
else
    set -- ./build_linux.sh "$@"
fi

# Same ccache settings as remote-build.sh: pch_defines,time_macros are required with precompiled
# headers; include_file_* lets a fresh checkout (new header mtimes) still hit.
docker run --rm --init \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}" \
    -e CCACHE_DIR=/ccache -e CCACHE_BASEDIR="${ROOT}" -e CCACHE_NOHASHDIR=1 -e CCACHE_COMPILERCHECK=content \
    -e CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-10G}" \
    -e CCACHE_SLOPPINESS=pch_defines,time_macros,include_file_mtime,include_file_ctime \
    -e ORCA_EXTRA_BUILD_ARGS="-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache ${ORCA_EXTRA_BUILD_ARGS:-}" \
    -v "${CCACHE_HOST_DIR}:/ccache" \
    -v "${ROOT}:${ROOT}" -w "${ROOT}" \
    "${IMAGE}" nice -n 10 "$@"
