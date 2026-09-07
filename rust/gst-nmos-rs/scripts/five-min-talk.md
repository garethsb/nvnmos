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
export CARGO_TARGET_DIR=$NVNMOS/rust/target
MXLLIB=$(dirname "$(find "$NVNMOS/../mxl/rust/target/release/build" -path '*/out/build/lib/libmxl.so' | head -1)")
export LD_LIBRARY_PATH=$NVNMOS_LIB_DIR${MXLLIB:+:$MXLLIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export GST_PLUGIN_PATH=$NVNMOS/rust/target/debug:$NVNMOS/../mxl/rust/target/release
```

`MXLLIB` is empty if gst-mxl-rs has not been built `--release`. UDP talk scripts do not need it; MXL ones `dlopen` `libmxl.so` by name.

## Once, before the talk

Confirm `libgstnmos.so` loads: `gst-inspect-1.0 nmos`. For MXL also
`gst-inspect-1.0 mxlsink` (needs the `GST_PLUGIN_PATH` / `LD_LIBRARY_PATH`
above).

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

**Terminals 1–3** — same plugin/lib path as the env block at the top, then:

```sh
cd "$NVNMOS/rust/gst-nmos-rs"
```

Talk pipelines omit `http-port` (nvnmosd allocates) and set `domain=local`.
UDP scripts look up the NIC with `ip` / `hostname -I` (or `DEMO_NIC_IP`);
loopback is rejected by `libnvnmos`. MXL scripts write
`/dev/shm/gst-nmos-rs-talk` (no NIC).

Pre-type, do not run yet. UDP or MXL:

**Terminal 1**

```sh
./scripts/talk-producer-udp.sh
# ./scripts/talk-producer-mxl.sh
```

**Terminal 2**

```sh
./scripts/talk-consumer-udp.sh
# ./scripts/talk-consumer-mxl.sh
```

**Terminal 3**

```sh
./scripts/talk-transformer-udp.sh
# ./scripts/talk-transformer-mxl.sh
```

## During the five minutes

If you need a GStreamer vocabulary primer (elements, pads, caps, bins), there's one in the [appendix](#appendix-gstreamer-vocabulary).

### GStreamer without NMOS

A pipeline is a graph of elements. You usually set their properties once. The media path for this talk already exists as stock
elements; NMOS is not required to send or receive ST 2110 or read or write MXL.

**RTP/UDP**:

```text
# send
… ! rtpvrawpay ! udpsink host=232.99.99.1 port=5004
# receive
udpsrc address=232.99.99.1 port=5004 multicast-iface=eth0 ! rtpvrawdepay ! …
```

Same idea on a hardware NIC with `nvdsudpsink` / `nvdsudpsrc`.

**MXL**:

```text
# write
… ! mxlsink domain=/dev/shm/gst-nmos-rs-talk flow-id=<uuid>
# read
mxlsrc domain=/dev/shm/gst-nmos-rs-talk video-flow-id=<uuid> ! …
```

Those properties are the session: multicast group, UDP port, MXL domain,
flow id. If you include them in a pipeline description for `gst-launch-1.0`, they stay whatever you typed. There's no way for an external controller to set a new
destination by updating `udpsink host=` or `mxlsink flow-id=`. You
would stop the pipeline, rebuild the string, or write an application that
tears out the inner elements and puts new ones in while the rest of the
graph keeps running.

**That is why `nmossink` / `nmossrc` exist.** Each is a bin element: ghost pad to
the rest of the pipeline, inner chain is `rtp*pay ! udpsink` / `udpsrc !
rtp*depay`, or `mxlsink` / `mxlsrc` (or nvdsudp). They add a Sender or
Receiver on `nvnmosd` (the NMOS Node), which serves IS-04 and IS-05; there is
no NMOS code in the pipeline. When a controller activates a connection, the
bin rebuilds the inner chain from the new transport file; `videotestsrc !
nmossink` and `nmossrc ! autovideosink` stay put.

Same pattern for audio channel mapping (not in this demo): without NMOS
you would set `audiomixer` / `audiomixmatrix` once. `nmosaudiochannelmap`
is a bin around that graph; an IS-08 PATCH of `/map/active` updates the
mix at runtime.

### Hit Return on the terminals

1. Return on T1, then T2. SMPTE bars on the consumer. In controller-ui, drag
   both Devices onto the canvas. Disable and enable the consumer Receiver
   (`video2`) — picture stops and starts.
2. Return on T3. A third Device (`transformer`) appears, Receiver `in` and
   Sender `out`, not yet flowing.
3. Connect transformer `in` to the producer Sender, then the consumer Receiver
   to transformer `out`. No-op: picture looks the same, path is now
   producer → transformer → consumer.
4. Ctrl+C T3. Replace `identity !` with one line from below.
   Return. Same `node-seed`, so reconnect in the UI if the Device dropped.
   Picture changes.

Leave T1 and T2 running during the talk; only restart T3 for the paste-in.

## Paste-ins

UDP caps are 1080p25 `UYVP`; MXL caps are 1080p25 `v210`. `videoflip` and the
text overlays cannot handle either, so those need a `videoconvert` sandwich
(convert back to `UYVP` or `v210` to match the script).

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

## Appendix: GStreamer vocabulary

**Pipeline and elements.** GStreamer runs media as a graph. Each
**element** does one job (read a file, packetize RTP, join multicast, draw to
a window). A **pipeline** is the graph that owns them and their state
(NULL → READY → PAUSED → PLAYING).

**Pads and buffers.** Elements pass data through **pads**: **sink** pads
are inputs, **src** pads are outputs. The payloads are **buffers**
(media plus timestamps and other metadata).

**GObject.** Pipelines, elements, pads, and buffers sit on GObject, so
they share property get/set, signals, and refcounting
(`gst_object_ref` / `unref`). You do not need the C API for this talk;
`gst-launch-1.0` is property assignment on elements.

**Properties.** Named knobs on an element or pad (`host=`, `port=`,
`pattern=smpte`, pad `::` properties). Applications can change them at
runtime; `gst-launch` sets them once when the pipeline is built. That
gap is why a controller PATCH cannot, by itself, retarget a bare
`udpsink`.

**Caps.** **GstCaps** describe the media format (encoding, width,
framerate, channels). Linked pads **negotiate** caps before buffers
flow. A `gst-launch` fragment such as
`video/x-raw,format=UYVP,width=1920,height=1080,framerate=25/1` is a
**capsfilter**: it constrains that link.

**Plugins.** Elements live in plugins (shared libraries).
`GST_PLUGIN_PATH` and `gst-inspect-1.0 nmos` / `mxlsink` are how this
demo finds `nmossink` and the MXL elements.

**Bins.** A **bin** is an element that contains other elements and is
still one object to the rest of the graph. An application can group
children in a generic `GstBin`. A **custom bin** subclasses `GstBin`,
exposes its own pads (**ghost pads** onto inner pads), and can rebuild
the inside without the outside unlinking. `nmossink` / `nmossrc` /
`nmosaudiochannelmap` are custom bins.

**Element shapes** (how many sink vs src pads):

| Shape | Pads | Role | Examples |
|-------|------|------|----------|
| Source | 0 sink, 1 src | Origin | `videotestsrc`, `filesrc`, `v4l2src`, `udpsrc`, `mxlsrc`, `nmossrc` |
| Sink | 1 sink, 0 src | Destination | `autovideosink`, `filesink`, `udpsink`, `mxlsink`, `nmossink` |
| Transform | 1 sink, 1 src | 1:1 process | `videoconvert`, `identity`, `capsfilter`, `rtpvrawpay` |
| Demux / parse | 1 sink, many src | Split a container | `qtdemux`, `matroskademux` |
| Mux / mix | many sink, 1 src | Combine | `mp4mux`, `audiomixer`, `compositor` |

**Pads that are not fixed at construction:**

- **Sometimes pads** — created when the stream is known. `decodebin`
  starts with a sink pad and adds src pads after it sees audio/video
  inside.
- **Request pads** — created when the application asks. `tee` (split
  one stream to many), `audiomixer` (extra inputs).
  `nmosaudiochannelmap` uses request pads (`sink_%u` / `src_%u`).

`nmossrc` and `nmossink` look like a source and a sink from the
outside. Inside the bin the shape is the ST 2110 or MXL chain, swapped in when NMOS activation arrives.
