#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Talk-only transformer. Defaults left off: daemon-uri
# (unix:/tmp/nvnmosd.sock), transport=udp, auto-activate=false,
# host-name (system hostname + .local), registration-url (DNS-SD).
# `interface-ip` / sender `source-ip` are required to synthesise the
# configuring SDP (must be a real NIC, not 127.0.0.1). Override with
# DEMO_NIC_IP. Replace `identity !` to transform.
set -euo pipefail

if [[ -z "${DEMO_NIC_IP:-}" ]]; then
    if command -v ip >/dev/null 2>&1; then
        DEMO_NIC_IP=$(ip -4 -o addr show 2>/dev/null \
            | awk '$2 != "lo" {print $4; exit}' \
            | cut -d/ -f1)
    fi
    DEMO_NIC_IP=${DEMO_NIC_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}
fi
if [[ -z "${DEMO_NIC_IP:-}" || "$DEMO_NIC_IP" == 127.* ]]; then
    echo "talk-transformer-udp: set DEMO_NIC_IP to a non-loopback IPv4 address" >&2
    exit 1
fi

exec gst-launch-1.0 -e \
    nmossrc \
        node-seed=example-transformer \
        node-properties="properties,label=transformer" \
        domain=local \
        receiver-name=in \
        interface-ip="$DEMO_NIC_IP" \
        transport-properties="properties,buffer-size=16777216" \
        caps="video/x-raw,format=UYVP,width=1920,height=1080,framerate=25/1,interlace-mode=progressive" \
        label="transformer in" ! \
    queue leaky=downstream max-size-buffers=2 max-size-bytes=0 max-size-time=0 ! \
    identity ! \
    videoconvert ! \
    videoflip method=vertical-flip ! coloreffects preset=sepia ! \
    clockoverlay time-format="%T" valignment=bottom shaded-background=true ! \
    timecodestamper ! timeoverlay time-mode=time-code valignment=bottom halignment=right shaded-background=true ! \
    videoconvert ! video/x-raw,format=UYVP ! \
    gdkpixbufoverlay location="$(dirname "$0")/../images/nvidia-logo-vert.svg" overlay-width=480 overlay-height=270 offset-x=240 offset-y=0 ! \
    nmossink \
        node-seed=example-transformer \
        node-properties="properties,label=transformer" \
        domain=local \
        sender-name=out \
        source-ip="$DEMO_NIC_IP" \
        transport-properties="properties,buffer-size=16777216" \
        caps="video/x-raw,format=UYVP,width=1920,height=1080,framerate=25/1,interlace-mode=progressive" \
        label="transformer out"
