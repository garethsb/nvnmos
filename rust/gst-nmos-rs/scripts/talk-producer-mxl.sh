#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Talk-only MXL producer. Defaults left off: daemon-uri
# (unix:/tmp/nvnmosd.sock), http-port (allocate), host-name,
# registration-url (DNS-SD). Same domain/flow as talk-consumer-mxl.sh.
set -euo pipefail

MXL_DOMAIN_PATH=/dev/shm/gst-nmos-rs-talk
MXL_DOMAIN_ID=dddddddd-8888-dddd-8888-dddddddddddd
MXL_VIDEO_FLOW=55555555-aaaa-5555-aaaa-555555555555

mkdir -p "$MXL_DOMAIN_PATH"
printf '{"id":"%s","label":"gst-nmos-rs talk domain"}\n' "$MXL_DOMAIN_ID" \
    >"$MXL_DOMAIN_PATH/domain_def.json"

exec gst-launch-1.0 -e \
    videotestsrc pattern=smpte is-live=true ! \
    video/x-raw,format=v210,width=1920,height=1080,framerate=25/1,interlace-mode=progressive ! \
    nmossink \
        transport=mxl \
        node-seed=talk-producer-mxl \
        node-properties="properties,label=producer-mxl" \
        domain=local \
        sender-name=video1 \
        mxl-domain-id="$MXL_DOMAIN_ID" \
        mxl-domain-path="$MXL_DOMAIN_PATH" \
        mxl-flow-id="$MXL_VIDEO_FLOW" \
        caps="video/x-raw,format=v210,width=1920,height=1080,framerate=25/1,interlace-mode=progressive" \
        label="producer-mxl out" \
        auto-activate=true
