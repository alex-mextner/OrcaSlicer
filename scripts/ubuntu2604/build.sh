#!/usr/bin/env bash
# Build Snapmaker Orca for Ubuntu 26.04 inside a container (no host sudo needed).
# The repo is mounted at the same absolute path so CMake caches stay valid on the host.
# Usage: scripts/ubuntu2604/build.sh [build_linux.sh flags]   (default: -dsr)
set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")
ROOT=$(readlink -f "${HERE}/../..")
IMAGE=snap-orca-build:26.04

docker image inspect "${IMAGE}" >/dev/null 2>&1 || docker build -t "${IMAGE}" "${HERE}"

[[ $# -eq 0 ]] && set -- -dsr

docker run --rm --init \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}" \
    -v "${ROOT}:${ROOT}" -w "${ROOT}" \
    "${IMAGE}" ./build_linux.sh "$@"
