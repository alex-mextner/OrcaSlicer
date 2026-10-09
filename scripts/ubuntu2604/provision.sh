#!/usr/bin/env bash
# Installs the Ubuntu 26.04 build environment for Snapmaker Orca (run as root). Shared by the
# Dockerfile (local container builds) and remote-build.sh (Runpod pods), so both build alike.
# Mirrors the package set of .github/workflows/build_orca.yml + scripts/linux.d/debian, adjusted
# for 26.04 package names. CMake 3.30 is used instead of the distro's 4.x because build_linux.sh
# refuses CMake >= 4 (deps fail to configure).
set -euo pipefail

CMAKE_VERSION=${CMAKE_VERSION:-3.30.8}
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    autoconf build-essential ca-certificates ccache curl eglexternalplatform-dev \
    extra-cmake-modules file gettext git libblosc-dev libcairo2-dev \
    libcurl4-openssl-dev libdbus-1-dev libfuse2t64 libgl1-mesa-dev libglew-dev \
    libglu1-mesa-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    libgstreamerd-3-dev libgtk-3-dev libmspack-dev libsecret-1-dev libsoup2.4-dev \
    libspnav-dev libssl-dev libtool libudev-dev libunwind-dev libwayland-dev \
    libwebkit2gtk-4.1-dev libxkbcommon-dev locales locales-all m4 ninja-build \
    pkgconf python3 sudo texinfo wayland-protocols wget xz-utils
rm -rf /var/lib/apt/lists/*

curl -fsSL "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz" \
    | tar -xz -C /opt
ln -sf /opt/cmake-${CMAKE_VERSION}-linux-x86_64/bin/* /usr/local/bin/
