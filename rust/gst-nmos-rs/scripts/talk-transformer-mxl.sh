#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Talk-only MXL transformer. Defaults left off: daemon-uri
# (unix:/tmp/nvnmosd.sock), auto-activate=false, host-name,
# registration-url (DNS-SD). Receiver `mxl-flow-id` is empty until the
# Controller connects it. Sender uses a second flow. Replace `identity !`
# to transform.
set -euo pipefail

MXL_DOMAIN_PATH=/dev/shm/gst-nmos-rs-talk
MXL_DOMAIN_ID=dddddddd-8888-dddd-8888-dddddddddddd
MXL_VIDEO_FLOW_OUT=66666666-aaaa-6666-aaaa-666666666666

mkdir -p "$MXL_DOMAIN_PATH"
printf '{"id":"%s","label":"gst-nmos-rs talk domain"}\n' "$MXL_DOMAIN_ID" \
    >"$MXL_DOMAIN_PATH/domain_def.json"

exec gst-launch-1.0 -e \
    nmossrc \
        transport=mxl \
        node-seed=talk-transformer-mxl \
        node-properties="properties,label=transformer-mxl" \
        domain=local \
        receiver-name=in \
        mxl-domain-id="$MXL_DOMAIN_ID" \
        mxl-domain-path="$MXL_DOMAIN_PATH" \
        caps="video/x-raw,format=v210,width=1920,height=1080,framerate=25/1,interlace-mode=progressive" \
        label="transformer-mxl in" ! \
    queue leaky=downstream max-size-buffers=2 max-size-bytes=0 max-size-time=0 ! \
    identity ! \
    videoconvert ! \
    videoflip method=vertical-flip ! coloreffects preset=sepia ! \
    clockoverlay time-format="%T" valignment=bottom shaded-background=true ! \
    timecodestamper ! timeoverlay time-mode=time-code valignment=bottom halignment=right shaded-background=true ! \
    videoconvert ! video/x-raw,format=v210 ! \
    gdkpixbufoverlay location="$(dirname "$0")/../images/nvidia-logo-vert.svg" overlay-width=480 overlay-height=270 offset-x=240 offset-y=0 ! \
    nmossink \
        transport=mxl \
        node-seed=talk-transformer-mxl \
        node-properties="properties,label=transformer-mxl" \
        domain=local \
        sender-name=out \
        mxl-domain-id="$MXL_DOMAIN_ID" \
        mxl-domain-path="$MXL_DOMAIN_PATH" \
        mxl-flow-id="$MXL_VIDEO_FLOW_OUT" \
        caps="video/x-raw,format=v210,width=1920,height=1080,framerate=25/1,interlace-mode=progressive" \
        label="transformer-mxl out"
