# Headless GUI test image for Snapmaker Orca AppImages (used by update-test.sh).
# The build image already carries the GTK/WebKit/GStreamer runtime libraries the AppImage expects
# from the host; this adds a private X server (Xvfb + openbox), UI automation (xdotool, wmctrl),
# screenshots (imagemagick `import`) and gdb for debugging a hung or crashed app by hand.
ARG BASE_IMAGE=snap-orca-build:26.04
FROM ${BASE_IMAGE}

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xvfb openbox xdotool wmctrl x11-utils imagemagick gdb libgl1-mesa-dri \
        gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav gstreamer1.0-gl \
    && rm -rf /var/lib/apt/lists/*
