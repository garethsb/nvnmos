#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Talk-only MXL consumer. Defaults left off: daemon-uri
# (unix:/tmp/nvnmosd.sock), http-port (allocate), host-name,
# registration-url (DNS-SD). Same domain/flow as talk-producer-mxl.sh.
set -euo pipefail

MXL_DOMAIN_PATH=/dev/shm/gst-nmos-rs-talk
MXL_DOMAIN_ID=dddddddd-8888-dddd-8888-dddddddddddd
MXL_VIDEO_FLOW=55555555-aaaa-5555-aaaa-555555555555

mkdir -p "$MXL_DOMAIN_PATH"
printf '{"id":"%s","label":"gst-nmos-rs talk domain"}\n' "$MXL_DOMAIN_ID" \
    >"$MXL_DOMAIN_PATH/domain_def.json"

exec gst-launch-1.0 -e \
    nmossrc \
        transport=mxl \
        node-seed=talk-consumer-mxl \
        node-properties="properties,label=consumer-mxl" \
        domain=local \
        receiver-name=video2 \
        mxl-domain-id="$MXL_DOMAIN_ID" \
        mxl-domain-path="$MXL_DOMAIN_PATH" \
        mxl-flow-id="$MXL_VIDEO_FLOW" \
        caps="video/x-raw,format=v210,width=1920,height=1080,framerate=25/1,interlace-mode=progressive" \
        label="consumer-mxl in" \
        auto-activate=true ! \
    queue leaky=downstream max-size-buffers=2 max-size-bytes=0 max-size-time=0 ! \
    videoconvert ! autovideosink sync=false
