<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

## `gst-nmos-rs` — integration test plan (property × caps × transport-file matrix)

Goal: exercise `nmossrc` / `nmossink` registration paths end-to-end — combinations of GObject properties, upstream caps, and `transport-file*` — and assert expected success or failure at NULL→READY, READY→PAUSED (deferred senders), and optionally PLAYING.

This complements the existing ~400 unit tests in `session/` and `sdp/` (synthesis, passthrough splice, `register_deferred`) and the single opt-in E2E test `tests/multi_flow_video_data.rs` (MXL + real buffers).

### What exists today

| Layer | Where | What it proves |
|-------|--------|----------------|
| Unit / session | `session/udp`, `session/mxl`, `sdp` | SDP synthesis, passthrough splice, `register_deferred`, `validate_and_open`, `InnerConfig` |
| One E2E | `tests/multi_flow_video_data.rs` (`#[ignore]`) | Full MXL pipeline + `nvnmosd`, real buffers |
| Manual / demo | `scripts/gst-nmos-rs-demo.sh`, README `gst-launch` examples | Happy paths, interactive IS-05 PATCH |

RTP deferred registration (READY→PAUSED `AddSender` from peer caps) is covered at session layer; element state machine + daemon behaviour for many input combinations is not.

### Recommendation: tiered Rust, shell as catalog only

**Primary: Rust** — matches `multi_flow_video_data.rs`: structured assertions, shared helpers (`nvnmosd` child process, temp UDS socket, programmatic pipeline build).

**Secondary: shell** — optional `scripts/gst-nmos-rs-matrix.sh` running a small curated subset via `gst-launch` for local debugging and README copy-paste. Not the source of truth for pass/fail (fragile log parsing, environment setup).

Grow coverage by **tier** and **axis**, not a full Cartesian product in one step.

### Test dimensions (matrix axes)

**Element:** `nmossink` (sender) first — deferred mode is sender-only; `nmossrc` separately for receiver registration.

**Transport:** `mxl` | `udp` | `udp2` | `nvdsudp` (`nvdsudp` may stay `#[ignore]` without DeepStream).

**Registration route** (mutually exclusive groups):

1. `transport-file` / `transport-file-path`
2. `caps=` (+ route-specific: `mxl-flow-id`, RTP endpoint props, `transport-caps`)
3. **Deferred:** neither — upstream `peer_query_caps` at READY→PAUSED

**RTP endpoint props** (when relevant): `source-ip`, `destination-ip`, `destination-port`, `interface-ip`, `multicast-ip`, `source-port` — unset vs set. Distinguish registration-only (`AddSender`) from `auto-activate=true` (real inner chain).

**Upstream caps:** fixated video / audio / ANC vs empty / ANY (deferred failure).

**Flags:** `auto-activate=true` | `false`.

**Expected outcome per checkpoint:**

| Checkpoint | Assert |
|------------|--------|
| NULL→READY | Session open; resource registered or not; `InnerConfig` Fake vs Real |
| READY→PAUSED | Deferred `AddSender`; state change success or pipeline-visible error |
| PLAYING | Optional: buffers on `fakesink` (tier 3 only) |

### Three tiers

#### Tier 1 — Session fixtures (extend incrementally)

Stay in `session/udp/mod.rs`, `session/mxl.rs`, `sdp.rs`.

- Deferred RTP × essence × minimal props
- Receiver passthrough matrix (multicast ASM/SSM, unicast file × property combos)
- Fast; always run in `cargo test -p gst-nmos-rs`

#### Tier 2 — Element + daemon smoke (highest ROI for new work)

New integration test crate file, e.g. `tests/registration_matrix.rs`:

- Spawn `nvnmosd` (reuse `DaemonGuard` pattern from `multi_flow_video_data.rs`)
- Build minimal pipelines programmatically (`gst::parse_launch` or `Pipeline::new`):
  - `videotestsrc ! capsfilter caps=… ! nmossink …` (deferred)
  - `fakesrc ! capsfilter ! nmossink caps=…` (explicit caps route)
  - `fakesrc ! nmossink transport-file-path=…`
- Drive `NULL → READY → PAUSED → READY → NULL`
- Assert GStreamer state return and/or error messages; optional daemon resource probe later

**Starter matrix (~15–25 cases, not hundreds):**

| Case | Expect NULL→READY | Expect READY→PAUSED |
|------|-------------------|---------------------|
| RTP deferred, video caps, `source-ip` set | Session, no resource, Fake | `AddSender` OK |
| RTP deferred, no `source-ip` | Session, no resource, Fake | Fail (`AddSender`) |
| RTP `caps=`, no transport-file | Resource registered | — |
| RTP multicast SDP + `interface-ip` only | Resource; spliced unicast `c=` | — |
| MXL deferred (peer caps) | Session, no resource | `AddSender` OK |
| Receiver: transport-file only | Resource registered | — |
| Receiver: no file, no caps | Fake `Misconfigured` | — |

#### Tier 3 — Media path E2E (later, selective `#[ignore]`)

Loopback unicast or lab multicast; buffers + IS-05 activation PATCH. Demo-script territory unless CI soak is required.

### Rust vs shell

| | Rust `tests/` | Shell matrix |
|--|---------------|--------------|
| Assertions | Strong (state, errors) | Log grep, exit codes |
| Maintenance | Table-driven `Case { … }` | Duplicated launch lines |
| CI | `#[ignore]` + opt-in job | Nightly / manual |
| Fits repo | Yes (`multi_flow_video_data`) | Demo script pattern |

**Verdict:** implement Tier 2 in Rust; optional thin shell wrapper for human-readable `gst-launch` strings only.

### Proposed layout

```
rust/gst-nmos-rs/
  tests/
    common/                       # shared: DaemonGuard, set_state, launch helpers
      mod.rs
    registration_matrix.rs        # Tier 2 table-driven cases
    multi_flow_video_data.rs      # existing MXL E2E
  tests/fixtures/sdp/             # multicast ASM/SSM, unicast baselines
    receiver_mcast_asm.sdp
    ...
```

Case sketch:

```rust
struct Case {
    name: &'static str,
    transport: Transport,
    side: Side,
    build_pipeline: fn() -> gst::Pipeline,
    expect_ready: ExpectReady,
    expect_paused: ExpectPaused,
}
```

### CI / local run

- **Default PR:** `cargo test -p gst-nmos-rs` (unit + Tier 1).
- **Opt-in:** `cargo test -p gst-nmos-rs --test registration_matrix -- --ignored` with `NVNMOSD_BIN`, `GST_PLUGIN_PATH` documented like README.
- **Future:** dedicated Linux job `integration-gst-nmos-rs` with plugins built.

### Phased rollout (suggested PR sequence)

1. **PR A:** `tests/common` + first Tier 2 cases for RTP deferred (on `feature/rtp-deferred-registration`).
2. **PR B:** Receiver registration routes (`transport-file*`, `caps=`, property overrides).
3. **PR C:** `auto-activate=true` smoke (Real inner at READY).
4. **PR D:** Expand matrix + fixture SDPs; explicit `interface-ip` passthrough cases.
5. **Optional:** `scripts/gst-nmos-rs-matrix.sh` for manual runs.

### Non-goals (for now)

- Full Cartesian product of all property combinations (unit passthrough matrix already covers splice logic).
- `nvdsudp` / DeepStream in default CI.
- Replacing the interactive demo script.
- Testing IS-05 controller behaviour beyond element activation acks.
