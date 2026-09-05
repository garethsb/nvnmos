#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Talk-only producer. Defaults left off: daemon-uri
# (unix:/tmp/nvnmosd.sock), transport=udp, http-port (allocate),
# host-name (system hostname + .local), registration-url (DNS-SD).
# `source-ip` is required to synthesise the configuring SDP (must be a
# real NIC, not 127.0.0.1). Override with DEMO_NIC_IP.
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
    echo "talk-producer-udp: set DEMO_NIC_IP to a non-loopback IPv4 address" >&2
    exit 1
fi

exec gst-launch-1.0 -e \
    videotestsrc pattern=smpte is-live=true ! \
    video/x-raw,format=UYVP,width=1920,height=1080,framerate=25/1,interlace-mode=progressive ! \
    nmossink \
        node-seed=talk-producer \
        node-properties="properties,label=producer" \
        domain=local \
        sender-name=video1 \
        destination-ip=232.99.99.1 \
        destination-port=5004 \
        source-ip="$DEMO_NIC_IP" \
        transport-properties="properties,buffer-size=16777216" \
        caps="video/x-raw,format=UYVP,width=1920,height=1080,framerate=25/1,interlace-mode=progressive" \
        label="producer out" \
        auto-activate=true
