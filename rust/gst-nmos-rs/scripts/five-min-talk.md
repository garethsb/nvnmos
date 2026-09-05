<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Five-minute gst-nmos-rs intro

Producer and consumer start themselves (`auto-activate=true`). The transformer
does not: connect it in NMOS Controller. Replace only the `identity !`
line to change the picture.

Commands below assume the nvnmos **repository root** as `$NVNMOS` and that
`libnvnmos` / `nvnmosd` / `libgstnmos.so` are already built (see the
[workspace quick start](../../README.md)).

```sh
export NVNMOS=$PWD
export NVNMOS_LIB_DIR=$NVNMOS/build
export LD_LIBRARY_PATH=$NVNMOS_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export GST_PLUGIN_PATH=$NVNMOS/rust/target/debug
export CARGO_TARGET_DIR=$NVNMOS/rust/target
```

## Once, before the talk

Confirm `libgstnmos.so` loads: `gst-inspect-1.0 nmos`.

If controller-ui cannot pull from NGC, build a local image and pass it in:

```sh
docker build -t controller-ui:prod $NVNMOS/../controller-ui
export CONTROLLER_UI_IMAGE=controller-ui:prod
```

Rehearse the four paste-ins below on this machine. The logo paste-in uses
`images/nvidia-logo-vert.svg`. Set both `overlay-width` and `overlay-height`
or the logo comes out stretched.

If 1080p25 UDP glitches, check:

```sh
sudo sysctl -w net.core.rmem_max=16777216 net.core.wmem_max=16777216
```

## Layout

| Where | What |
|-------|------|
| Browser | http://127.0.0.1:3000 (Controller) |
| Terminal R | Registry + Controller (this script, leave running) |
| Terminal D | `nvnmosd` |
| Terminal 1 | producer — Return when you start talking |
| Terminal 2 | consumer — Return next |
| Terminal 3 | transformer — Return after the stop/start beat |
| Editor | this file, for paste-ins |

## Bring-up (leave running)

**Terminal R** — NMOS Registry (nmos-cpp) and NMOS Controller (controller-ui):

```sh
cd "$NVNMOS/rust/gst-nmos-rs"
CONTROLLER_UI_IMAGE=controller-ui:prod \
    ./scripts/start-nmos-registry-and-controller.sh
```

Open http://127.0.0.1:3000. Leave this terminal in the foreground (Ctrl+C
tears both containers down). The Registry uses Docker bridge networking so
its mDNS advertisements reach the host's Avahi daemon.

The script runs the Registry container as `nmos-registry` and adds an
`/etc/hosts` entry for `nmos-registry.local`, so it prompts for `sudo` once.
Nodes resolve that name with `getaddrinfo` when they register, and where
`libnss-mdns` is slow it takes about ten seconds, which is long enough to be
annoying.

**Terminal D** — daemon:

```sh
export NVNMOS_LIB_DIR=$NVNMOS/build
export LD_LIBRARY_PATH=$NVNMOS_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
cd "$NVNMOS/rust"
./target/debug/nvnmosd --uds /tmp/nvnmosd.sock
```

**Terminals 1–3** — same plugin/lib path, then:

```sh
export NVNMOS_LIB_DIR=$NVNMOS/build
export LD_LIBRARY_PATH=$NVNMOS_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export GST_PLUGIN_PATH=$NVNMOS/rust/target/debug
cd "$NVNMOS/rust/gst-nmos-rs"
```

Talk pipelines omit `http-port` (nvnmosd allocates), set `domain=local`, and
look up the NIC with `ip` / `hostname -I` (or `DEMO_NIC_IP`). Loopback is
rejected by `libnvnmos`.

Pre-type, do not run yet:

**Terminal 1**

```sh
./scripts/talk-producer-udp.sh
```

**Terminal 2**

```sh
./scripts/talk-consumer-udp.sh
```

**Terminal 3**

```sh
./scripts/talk-transformer-udp.sh
```

## During the five minutes

1. One sentence: `nmossink` / `nmossrc` are GStreamer elements; `nvnmosd` is the
   NMOS Node. You did not write IS-04/IS-05.
2. Return on T1, then T2. SMPTE bars on the consumer. In controller-ui, drag
   both Devices onto the canvas. Disable and enable the consumer Receiver
   (`video2`) — picture stops and starts.
3. Return on T3. A third Device (`transformer`) appears, Receiver `in` and
   Sender `out`, not yet flowing.
4. Connect transformer `in` to the producer Sender, then the consumer Receiver
   to transformer `out`. No-op: picture looks the same, path is now
   producer → transformer → consumer.
5. Ctrl+C T3. Replace `identity !` with one line from below.
   Return. Same `node-seed`, so reconnect in the UI if the Device dropped.
   Picture changes.

Leave T1 and T2 running during the talk; only restart T3 for the paste-in.

## Paste-ins

Caps are 1080p25 `UYVP`, which `videoflip` and the text overlays cannot handle,
so those need a `videoconvert` sandwich.

```text
    videoconvert ! \
    videoflip method=vertical-flip ! coloreffects preset=sepia ! \
    videoconvert ! video/x-raw,format=UYVP ! \
```

```text
    videoconvert ! \
    clockoverlay time-format="%T" valignment=bottom shaded-background=true ! \
    videoconvert ! video/x-raw,format=UYVP ! \
```

```text
    videoconvert ! \
    timecodestamper ! timeoverlay time-mode=time-code valignment=bottom halignment=right shaded-background=true ! \
    videoconvert ! video/x-raw,format=UYVP ! \
```

```text
    gdkpixbufoverlay location="$(dirname "$0")/../images/nvidia-logo-vert.svg" overlay-width=480 overlay-height=270 offset-x=240 offset-y=0 ! \
```

## After

Ctrl+C T1–T3, then D, then R.

If Docker bridge networking is unavailable, set
`DEMO_REGISTRY_DOCKER_NETWORK=host` and use an explicit `registration-url`;
host-network mDNS advertisements may be discarded as self-originated by the
host's Avahi daemon.
