<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Filesystem-backed NMOS resources for `nvnmosd`

Status: proposed design

Scope: a new `nvnmosd-fs` companion application, one small libnvnmos /
`nvnmosd` addition for read-only active IS-05 state, and filesystem-backed RTP
and MXL Senders and Receivers. MXL input is either a directory of
`.flow_def.json` files or an MXL Domain directory. The last step is a web
editor for writing the flat SDP and MXL files.

## 1. Goal

Expose externally managed media endpoints as NMOS resources by reconciling
typed directories into `nvnmosd`.

The filesystem is authoritative for the active media state. An MXL Domain is
one of those directories: the same reconciliation rules, with a nested layout
owned by the MXL writer.

```text
typed directory          -> authoritative media state
nvnmosd-fs               -> observes and reconciles state
nvnmosd                  -> exposes the resulting NMOS model
IS-05 controllers        -> may inspect and stage, but cannot change active state
```

The initial useful result is:

- configured directories, each of one kind: SDP files, MXL `.flow_def.json`
  files, or an MXL Domain;
- Sender and Receiver sides for the file directories; an MXL Domain contributes
  Senders only;
- deterministic NMOS identity from the relative path, or from the Domain's
  logical name plus flow id;
- create, update, rename, and remove reconciliation, including flow appearance
  and disappearance inside a Domain;
- controller-originated IS-05 activation rejected before `/active` changes;
- application-originated state published with `SyncResourceState`;
- no persistent database in `nvnmosd-fs`.

That directory reconciliation is useful on its own: a shell `cp` or `rm` is
enough to create, update, and remove resources. The web editor is the last
step of the same work. It is how an operator writes and checks those flat SDP
and MXL files without leaving the browser. It does not manage MXL Domain
directories, because those stay owned by the MXL writer.

## 2. Non-goals

`nvnmosd-fs` does not:

- start, stop, or reconfigure the external media endpoint;
- make IS-05 the owner of the data plane;
- introduce another resource-description format;
- rewrite source files to add NvNmos extensions;
- maintain a database alongside the filesystem;
- infer missing media-format fields from filenames or defaults;
- infer a directory's transport by inspecting a mixture of files;
- require changes to MXL flow writers.

## 3. Existing NvNmos behaviour

### 3.1 Configuring transport files

NvNmos already accepts the two required formats:

- RTP/UDP: SDP;
- MXL: MXL `flow_def` JSON.

The configuring transport file supplies the initial IS-04 resources and IS-05
connection state. `SyncResourceState` is the existing application-originated
path for reporting a later active state. It updates `/active` and does not
invoke the application's activation callback.

### 3.2 Identity

NvNmos derives stable resource UUIDs from:

```text
Node seed + side + caller-chosen name
```

A Sender name identifies its Source, Flow, and Sender. A Receiver name
identifies its Receiver. Sender and Receiver names occupy separate namespaces.

The embedded configuring-transport-file name is currently required:

- SDP: session-level `a=x-nvnmos-name:<name>`;
- MXL: `tags["urn:x-nvnmos:tag:name"] = ["<name>"]`.

`AddSenderRequest.name` or `AddReceiverRequest.name` must match that embedded
value.

### 3.3 Activation rejection is currently too late

The current nmos-cpp activation sequence is:

1. merge the requested staged state into `/active`;
2. update the corresponding IS-04 subscription;
3. invoke the application activation callback.

The callback is a notification after the model update. Returning `false` from
`nmos_connection_activation_callback`, or sending
`AckActivation { success: false }`, does not roll back `/active`.

This applies to:

- immediate and scheduled activation;
- transport parameter changes;
- `master_enable` changes;
- Senders and Receivers.

For a scheduled activation, the controller has already received the acceptance
response before the callback runs. Reapplying the filesystem state afterwards
would briefly publish state that was never active in the external endpoint and
is not an acceptable read-only implementation.

### 3.4 Activation-failure documentation is inconsistent

nmos-cpp is consistent with itself. `connection_activation_handler` is a
`void` notification that `/active` has already changed. Its contract says the
callback must not throw, because that change will not be rolled back. The
immediate-activation 500 response is for resolving `"auto"` throwing before
that assignment.

NvNmos documents a failure return that its implementation does not perform:

- `doc/user/concepts.md` says the application can reject the activation and
  that an immediate failure is reported to the controller.
- `AckActivation` in `nvnmosd.proto` says success updates the NMOS state, the
  result is returned to the controller, and `failure_reason` is surfaced to
  the controller.
- `NodeServerBuilder::on_activation` says `Err` reports failure to the IS-05
  controller. The activation trampoline says `false` does the same.
- `doc/designs/nvnmosd/README.md` says NvNmos updates IS-04 and IS-05 when the
  callback returns success, and that the outcome stays visible at IS-05.

The implementation logs `false` from `nmos_connection_activation_callback` and
does not throw. An immediate PATCH therefore still succeeds, with `/active`
left at the requested state. `state.rs` is closer when it says the failure
reason is only logged.

Correcting those documents, and deciding whether a `false` callback should
make an immediate request fail, can be an independent fix or part of the
read-only-active work in section 4. Either way it does not provide the
read-only guarantee: a failure signal after the callback still leaves
`/active` already changed.

## 4. Required read-only-active mode

### 4.1 Contract

A Node used by `nvnmosd-fs` needs a connection-management mode with this
contract:

- a PATCH that only changes `/staged` transport state is allowed;
- a PATCH that requests immediate or scheduled activation is rejected;
- rejection occurs before `/active` or the IS-04 subscription changes;
- application-originated `nmos_connection_activate` /
  `SyncResourceState` remains allowed;
- Nodes not using this mode retain their current IS-05 behaviour.

This permits controllers to prepare or inspect proposals without allowing them
to take ownership of active media state.

### 4.2 libnvnmos implementation

Use nmos-cpp's existing `connection_resource_patch_validator`. It receives the
merged `/staged` value before an activation is scheduled. The validator is
currently empty in `make_node_implementation_patch_validator`.

Add a per-Node policy to `NvNmosNodeConfig` and the corresponding nvnmosd
`NodeConfig`. Use a zero-default enum rather than a Boolean whose zero value
would change existing applications:

```text
ALLOW_ACTIVATION       (default)
READ_ONLY_ACTIVE
```

In `READ_ONLY_ACTIVE`, the merged-patch validator rejects any non-null
activation mode. Both single-resource and bulk IS-05 PATCHes use this
validation path. A transport-only staged PATCH continues to succeed.

`nvnmosd-fs` still keeps `SubscribeActivations` open because nvnmosd requires
an active subscription before adding resources. Any event which reaches the
stream is acknowledged as failed and logged as an invariant violation. That is
only a backstop; correctness comes from pre-activation validation.

### 4.3 Verification

Focused HTTP tests must cover both Sender and Receiver resources:

1. a transport-only staged PATCH succeeds and leaves `/active` unchanged;
2. immediate activation is rejected and leaves `/active` byte-for-byte
   unchanged;
3. scheduled-absolute activation is rejected and is never applied later;
4. scheduled-relative activation is rejected and is never applied later;
5. a request changing transport parameters and activating is rejected;
6. a request changing `master_enable` and activating is rejected;
7. a bulk request containing an activation is rejected without changing any
   participating resource;
8. `SyncResourceState` still updates `/active`;
9. the default policy still accepts normal IS-05 activation.

Tests should compare the full previous `/active` value and the associated IS-04
subscription, not only the HTTP status.

## 5. Filesystem model

### 5.1 Typed directories

Each configured directory has one kind and, for file directories, one side.
`nvnmosd-fs` does not accept a directory that mixes SDP and MXL resources.
The kind selects the scan rule; a file that does not match that rule is
ignored and logged, not parsed as the other transport.

| Kind | Side | What is a resource |
| --- | --- | --- |
| `sdp` | Sender or Receiver | `*.sdp`, including under subdirectories |
| `mxl` | Sender or Receiver | `*.flow_def.json`, including under subdirectories |
| `mxl-domain` | Sender only | `<flow-id>.mxl-flow/flow_def.json` |

File-directory examples:

```text
/var/lib/nvnmos/sdp-senders/program.sdp
/var/lib/nvnmos/sdp-senders/news/program.sdp
/var/lib/nvnmos/mxl-senders/graphics.flow_def.json
/var/lib/nvnmos/sdp-receivers/monitor.sdp
```

The normalized path relative to the configured root is the caller-chosen name:

```text
/var/lib/nvnmos/sdp-senders/news/program.sdp -> news/program.sdp
```

The suffix is part of that name, so `program.sdp` and `program.flow_def.json`
are different resources. Sender and Receiver names remain separate NvNmos
namespaces, so the same relative path may exist on both sides. Two directories
of the same side must not produce the same name; the second resource is logged
and not published.

Absolute paths are not used as names. Moving a configured root must not change
every NMOS UUID. Paths containing `..`, paths which escape the root through a
symbolic link, and non-UTF-8 relative paths are rejected. Editor temporary
files and dotfiles are ignored.

An MXL Domain is the same idea with the layout the MXL writer already uses:

```text
<domain>/domain_def.json
<domain>/<flow-id>.mxl-flow/flow_def.json
<domain>/<flow-id>.mxl-flow/access
<domain>/<flow-id>.mxl-flow/data
<domain>/<flow-id>.mxl-flow/grains/
```

Only `flow_def.json` inside a `<flow-id>.mxl-flow` directory is a Sender. The
fixed filename `flow_def.json` is the Domain's flow document; it is not the
`*.flow_def.json` pattern used by an `mxl` file directory. `domain_def.json`,
shared-memory files, and anything else in the tree are not resources.
Configuring a Domain path as kind `mxl` would miss those flows and must be
rejected by the operator's configuration, not discovered by content sniffing.

### 5.2 Name overlay

The directory-derived name is authoritative even when the source document
already contains an NvNmos name. Before every add or sync, `nvnmosd-fs`
constructs an in-memory configuring transport file:

- SDP: remove all session-level `a=x-nvnmos-name` attributes and insert one
  containing the relative path;
- MXL file or Domain flow: replace `tags["urn:x-nvnmos:tag:name"]` with a
  one-string array containing the caller-chosen name.

For an `sdp` or `mxl` directory that name is the relative path. For an
`mxl-domain` directory it is:

```text
<logical Domain name>/<flow UUID>
```

The logical Domain name comes from configuration, not from the host path, so
moving the Domain directory does not change Sender UUIDs. The flow UUID is the
`<flow-id>.mxl-flow` directory name.

The source file is never rewritten. Existing embedded names cannot override
the path, collide with another file, or survive a rename.

All other fields and extensions are preserved, including:

- label and description;
- group hint;
- Receiver caps selection;
- RTP interface metadata and source port;
- an explicitly configured MXL Domain ID;
- the top-level MXL flow `id`.

### 5.3 In-memory state

The application keeps:

```text
(side, caller-chosen name) -> resource handle, digest, last valid effective
                              file, removal deadline
```

The map is runtime state, not persistence. Stable Node seed and relative names
provide persistent NMOS identity.

The digest is calculated from the effective in-memory transport file after
the name overlay. It avoids unnecessary nvnmosd calls after duplicate or
coalesced filesystem events.

## 6. Reconciliation

### 6.1 Startup

On startup:

1. connect to `nvnmosd`;
2. open or attach a session on a stable, configured Node seed using
   `READ_ONLY_ACTIVE`;
3. open `SubscribeActivations`;
4. scan every configured directory;
5. parse and validate every supported file;
6. add valid resources and publish their active state;
7. log invalid files without aborting other resources;
8. start filesystem watching and periodic reconciliation.

Resources are owned by the companion's nvnmosd session. Closing or garbage
collecting the old session removes its resources, so `nvnmosd-fs` does not
need a separate ownership marker in the NMOS model. After an `nvnmosd`
restart, it opens a new session and reconstructs the model from the roots.

### 6.2 Create

When a supported file appears:

1. wait for a completed write event where the platform exposes one;
2. read a stable snapshot;
3. parse and validate it;
4. overlay the relative-path name;
5. call `AddSender` or `AddReceiver`;
6. call `SyncResourceState` with the effective transport file.

The scan/retry path remains authoritative. Correctness must not depend on
receiving one particular filesystem event.

### 6.3 Modify

When a known file changes:

1. read, parse, and validate the replacement;
2. overlay the same name;
3. retain the previous valid resource if the replacement is invalid;
4. reconcile the resource when the replacement is valid.

There are two kinds of valid update:

**Active-state-only update**

When the change can be represented by `SyncResourceState`, keep the existing
resource handle and update active IS-05 state.

**Resource-description update**

`SyncResourceState` does not reconstruct all associated IS-04 Source, Flow,
Sender, or Receiver fields. A change to media format, caps, label,
description, group hint, or other add-time metadata requires:

1. deactivate the existing resource;
2. remove it;
3. add it again under the same caller-chosen name;
4. publish the new active state.

The NMOS UUIDs remain unchanged because the Node seed, side, and name are
unchanged, although observers may see a brief remove/add interval. The
implementation should begin conservatively: use in-place sync only for fields
proven to be covered by `SyncResourceState`; otherwise replace.

### 6.4 Invalid replacement

An invalid replacement never destroys the last known-good state. Log the file,
parse or validation error, and continue exposing the previous state until:

- a valid replacement is supplied; or
- the file is removed and the removal policy expires.

Repeated scans should suppress duplicate logs for the same invalid file
content while still reporting a changed error.

### 6.5 Rename

A rename that changes the relative path is:

```text
remove old name + add new name
```

It intentionally changes the NMOS UUIDs. If a deployment needs stable identity
across a content update, it must atomically replace the contents at the same
destination path rather than rename the destination itself.

### 6.6 Remove

The default policy is:

1. immediately call `SyncResourceState` without a transport file, setting
   `master_enable=false`;
2. retain the resource for a configurable grace period;
3. remove it when the deadline expires.

If the same path returns with valid content during the grace period, cancel
removal and resynchronize the existing resource handle.

Also support immediate removal for deployments which do not want the grace
period. A default grace period of 30 seconds is suitable for the initial
implementation and protects against editors and deployment tools which briefly
remove the destination.

## 7. Filesystem observation

Use filesystem notification as a latency optimization and full reconciliation
as the source of correctness.

The watcher should handle:

- create;
- close-after-write or the platform's nearest equivalent;
- modification;
- atomic replacement;
- delete;
- rename;
- watched-directory replacement.

After a short debounce, reconcile the affected path from current filesystem
state rather than assigning semantics directly to the raw event sequence.
Perform a configurable periodic full rescan to recover from missed, overflowed,
or coalesced events.

Writers, including the web editor, should use:

```text
write temporary file -> flush/fsync as required -> atomic rename into place
```

## 8. MXL Domain directories

### 8.1 Input

An `mxl-domain` directory contributes live Senders. Each flow is:

```text
<domain>/<flow-id>.mxl-flow/flow_def.json
```

The flow definition is already the IS-04-like description consumed by
libnvnmos. Reconciliation must not modify `flow_def.json` or any other file
in the Domain; the MXL writer owns them.

### 8.2 Domain identity

When `<domain>/domain_def.json` exists, its required `id` is the authoritative
MXL Domain UUID. Overlay it into the in-memory flow definition as:

```json
"urn:x-nvnmos:tag:mxl-domain-id": ["<domain UUID>"]
```

If `domain_def.json` is absent, leave the Domain application-resolved:
`mxl_domain_id` remains unconstrained and `/active` carries null.

A present but unreadable or invalid `domain_def.json`, a missing or empty
`id`, or a non-UUID `id` is a Domain-level error. Do not publish flows from
that Domain until it becomes valid. Never invent a Domain UUID from its path.

### 8.3 Flow identity and overlay

The flow directory name supplies the observed MXL flow ID. Cross-check it
against the top-level `id` in `flow_def.json`; reject the flow on mismatch.
Preserve that top-level `id`, which constrains IS-05 `mxl_flow_id`.

Overlay the NvNmos caller-chosen name from section 5.2 because a live flow
definition does not contain `urn:x-nvnmos:tag:name`. The logical Domain name
disambiguates several application-resolved Domains watched by one Node.

Preserve standard flow tags, including group hint. Do not add the Receiver
caps marker: a Domain directory creates Senders. Do not synthesize absent
`label`, `description`, media-format, or structural flow fields. A flow
definition missing fields required by libnvnmos is invalid and remains
unpublished until corrected by its owner.

### 8.4 Lifecycle

Flow appearance, valid modification, invalid replacement, disappearance, and
return use the same reconciliation and grace-period rules as filesystem-backed
Sender files.

A `domain_def.json` ID change changes Domain identity. Reconcile all flows in
that Domain and log the identity change prominently. Deployments should treat
such a change as replacing the Domain, not as a routine metadata update.

The Domain scan is the nested form of the `mxl` file scan. Implement it with
the same parse, overlay, add, sync, replace, and remove functions. It is part
of the first release, after the flat file directories are reconciling.

## 9. Configuration

Connection to `nvnmosd` follows that daemon's command-line and environment
conventions: UDS path, Node seed, and the normal Node configuration.

The directory list belongs in a small configuration file. Each entry is a
path, a kind (`sdp`, `mxl`, or `mxl-domain`), and a side. Kind `mxl-domain`
is Sender-only and also carries the logical Domain name used in section 5.2.
Repeated flags are a poor fit once one process watches several directories.

```yaml
directories:
  - path: /var/lib/nvnmos/sdp-senders
    kind: sdp
    side: sender
  - path: /var/lib/nvnmos/sdp-receivers
    kind: sdp
    side: receiver
  - path: /var/lib/nvnmos/mxl-receivers
    kind: mxl
    side: receiver
  - path: /dev/shm/studio
    kind: mxl-domain
    side: sender
    name: studio
```

Optional settings are:

- removal mode (`disable-then-remove` or `immediate`);
- removal grace period, default 30 seconds;
- rescan interval.

Do not add settings for information already carried by SDP or a flow
definition. Reject a `mxl-domain` entry with side `receiver`, a Domain entry
without `name`, and two entries whose derived names collide on the same side.

## 10. Failure and recovery

### 10.1 `nvnmosd-fs` restart

The old session is closed or garbage collected, removing its resources. The
new process scans authoritative inputs and recreates them with the same Node
seed and names, producing the same UUIDs.

### 10.2 `nvnmosd` restart or connection loss

Treat the daemon connection and session as replaceable:

1. stop issuing reconciliation calls;
2. retain the desired filesystem snapshot;
3. reconnect with bounded backoff;
4. open a new session and activation stream;
5. replay the current desired state.

Do not queue every intermediate filesystem event while disconnected. A fresh
scan gives the desired state directly.

### 10.3 Partial reconciliation failure

One invalid file or failed resource operation must not stop unrelated
resources. Keep a per-path error and retry after a relevant event, periodic
rescan, or daemon reconnection.

When replacement requires remove/add and the add fails, retain the desired
state and retry. The previous resource cannot be restored blindly unless its
last valid configuring transport file is still available and restoration is
known to be safe.

## 11. Web editor

The web editor is the last implementation step. Directory reconciliation
already works from the shell; the editor is the interface for writing the
files that reconciliation consumes. It adds, replaces, and removes files in
`sdp` and `mxl` directories `nvnmosd-fs` is already watching, with syntax
checking and a form for the usual fields. It is not an NMOS control plane, and
it does not create the directory configuration.

### 11.1 What it edits

The editor lists the configured `sdp` and `mxl` directories and the files
already in them, on both the Sender and Receiver sides. The operator picks one
of those directories and then:

- adds a file;
- replaces the contents of a file;
- removes a file.

It does not add, rename, or remove configured directories, and it has no
control for creating a new directory level. A file added in the editor is a
single path inside the selected directory. An `mxl-domain` directory is not
shown as a destination. The editor does not copy a live Domain flow into a
flat directory, and it does not write a flat file into a Domain. Domain files
stay owned by the MXL writer.

The chosen relative path is the caller-chosen name, including `.sdp` or
`.flow_def.json`. For a new pasted or uploaded document, an existing
`a=x-nvnmos-name` or `urn:x-nvnmos:tag:name` value may prefill the filename
when it is a valid single filename; the editor adds the suffix when needed.
An invalid name, a name containing a directory separator, or a collision is
reported and left for the operator to resolve.

The path remains authoritative. Editing the embedded name in an existing file
does not rename the resource. A mismatch is a warning, with an action to update
the document visibly to match the filename before saving. Form-generated files
keep the embedded name synchronized automatically. The server does not rewrite
the document silently, and `nvnmosd-fs` still overlays the path when it
reconciles files created outside the editor.

### 11.2 Writing the file

Saving is the same for a new file and an edit: the editor holds one document,
checks it, and only then asks the companion's write path to store it.

Two views edit that document:

- a text view, for paste, upload, and direct editing of SDP or flow-definition
  JSON;
- a form view, for the fields an operator normally sets: label, description,
  media format, addresses and ports, group hint, the unconstrained-caps
  marker, and, for a flat MXL file, an explicit Domain id.

The text view is the document. The form reads it and writes it back. Highlighting
and local checks use existing browser libraries. The editor does not implement
its own JSON parser, SDP parser, or syntax highlighter.

An existing editor component provides the text view. JSON highlighting and
well-formedness come from that component, or from another maintained JSON
library. SDP highlighting comes from an existing SDP or plaintext mode. Local
MXL checks use a JSON Schema validator in the browser. Local SDP checks may
call the pure check functions from [SDPoker](https://github.com/AMWA-TV/sdpoker)
(`checkRFC4566`, `checkRFC4570`, `checkST2110`). Those functions take an SDP
string and do not read files. The package itself is CommonJS for Node: its
entry point uses `fs`, and it is not published as a browser bundle. Import the
check modules, not `getSDP`. SDPoker does not know the NvNmos SDP extensions,
so a document can pass it and still be rejected by libnvnmos.

The MXL schema is based on the IS-04 Flow schemas and is not one of them. A
configuring flow definition does not carry Flow fields such as `source_id` and
`device_id`, and its `media_type` values include MXL types such as
`video/v210` and `audio/float32` rather than only `video/raw`. The schema
reuses the structural pieces (`grain_rate`, `components`, `colorspace`, and
so on), allows the NvNmos tag keys, and leaves room for tags the form does
not edit. It drives the form and the local diagnostics. It is not the
reconciliation rule.

The browser checks are for editing. Every save is validated again on the
server with the same parse `nvnmosd-fs` uses before add, against the bytes
that will be renamed into place. An invalid document is not written. A file
that arrives by some other means is still checked by reconciliation.

If an existing file contains structure the form does not represent, the editor
opens it in the text view and says so. Saving from the form must not drop
those lines. Upload and paste therefore stay available for a document the form
cannot round-trip.

### 11.3 How a file is stored

The editor:

- uses the same path checks as `nvnmosd-fs`;
- writes through a temporary file and an atomic rename into the selected
  directory;
- leaves the saved file for `nvnmosd-fs` to reconcile into NMOS state.

Removing a file removes it from the directory. The companion then applies the
configured removal policy.

The editor keeps no database and does not call `nvnmosd`. It does not itself
disable or delete the NMOS resource.

Authentication, authorization, TLS, and multi-user editing are separate
deployment concerns and must be designed before exposing the editor beyond a
trusted management network.

## 12. Implementation increments

### 12.1 Read-only active state

- add the per-Node activation policy to libnvnmos and nvnmosd;
- reject activation-bearing PATCHes in the merged-staged validator;
- add the HTTP tests from section 4.3;
- verify the default policy remains unchanged.

This increment must land first. Activation callback failure is not a substitute.

The documentation mismatch in section 3.4 can be corrected in this increment
or separately. If a `false` callback is later made to fail an immediate
request, that still does not roll back `/active` and does not replace the
validator.

### 12.2 Single-file prototype

- add the `nvnmosd-fs` crate and executable;
- open a session and activation stream;
- load one Sender or Receiver file;
- overlay its relative-path name;
- add and activate it;
- verify UUID stability across process restarts.

### 12.3 Startup directory scan

- scan configured `sdp` and `mxl` directories;
- accept only `*.sdp` or `*.flow_def.json` for the directory kind;
- ignore a file of the other kind;
- isolate invalid-file failures;
- record last valid effective files.

### 12.4 Watch and reconcile

- add filesystem notifications;
- debounce into path reconciliation;
- implement create, valid update, invalid replacement, rename, and remove;
- add periodic full rescan.

### 12.5 Removal policy and recovery

- deactivate immediately and remove after the grace period;
- support immediate removal;
- cancel pending removal when a valid file returns;
- reconnect and replay after daemon restart or connection loss.

### 12.6 MXL Domain directories

- read and validate `domain_def.json`;
- enumerate `<flow-id>.mxl-flow/flow_def.json`;
- ignore the rest of the Domain tree;
- cross-check flow IDs;
- overlay Domain ID and `<logical name>/<flow UUID>`;
- apply the same appearance/update/disappearance lifecycle.

This increment is part of the first release. It is ordered after flat
directories because it reuses their reconciliation, not because a Domain is a
separate product.

### 12.7 Web editor

This is the last step, after flat directories and MXL Domain reconciliation
are in place. The companion is already useful at that point. The editor is
still part of the work: it is the way an operator authors the flat files.

- list configured `sdp` and `mxl` directories and their files;
- add, replace, and remove files in those directories;
- refuse directory creation and every write into an `mxl-domain` directory;
- check SDP or flow-definition syntax before save, and do not write an invalid
  document;
- edit the same document as text or as a form, without the form discarding
  text it does not represent;
- store files by temporary file and atomic rename, then let `nvnmosd-fs`
  reconcile them.

## 13. Test plan

### 13.1 Unit tests

- relative-path normalization and rejection;
- SDP name replacement, including duplicate existing attributes;
- MXL name replacement while preserving unrelated tags;
- `sdp` and `mxl` suffix classification, including a foreign file ignored;
- `mxl-domain` recognition of `<flow-id>.mxl-flow/flow_def.json` only;
- digest and no-op reconciliation;
- valid and invalid `domain_def.json`;
- flow-directory ID and top-level `id` agreement;
- removal deadline cancellation.

### 13.2 nvnmosd integration tests

- all read-only-active HTTP cases in section 4.3;
- add and sync RTP Sender and Receiver;
- add and sync MXL Sender and Receiver;
- same relative name on opposite sides;
- deterministic IDs after remove/add;
- metadata-changing replacement keeps UUIDs;
- activation events are not emitted for `SyncResourceState`.

### 13.3 Filesystem integration tests

- initial scan;
- atomic create;
- in-place modification;
- atomic replacement;
- invalid replacement retains last valid state;
- rename changes identity;
- remove disables immediately and removes after the grace period;
- rapid remove/recreate preserves the resource handle;
- missed event recovered by rescan;
- companion restart;
- daemon restart;
- files changed while disconnected.

Run watcher tests against real temporary directories. Keep event-order
assertions out of the tests; assert the reconciled result.

### 13.4 MXL Domain integration tests

- Domain with a concrete `domain_def.json` ID;
- application-resolved Domain without `domain_def.json`;
- malformed Domain definition suppresses all Domain flows;
- flow appears, changes, disappears, and returns;
- flow ID mismatch is rejected;
- standard tags survive the overlay;
- writer-owned files remain byte-for-byte unchanged.

### 13.5 Web editor

- a flat Sender or Receiver file can be added, replaced, and removed;
- an invalid document is rejected before it reaches the directory;
- the form round-trips a document it understands, and leaves a document it
  does not understand in the text view;
- an `mxl-domain` path is not a write target;
- the editor does not create a configured directory;
- after a successful save, reconciliation sees the same file a shell `cp` or
  `rm` would have produced.

## 14. Documentation and examples

Document:

- installation and invocation;
- typed directories and the MXL Domain layout;
- `.sdp` and `.flow_def.json`;
- relative-path and Domain naming, and deterministic UUIDs;
- embedded-name override;
- active-state ownership and IS-05 behaviour;
- update and replacement semantics;
- invalid-file retention;
- removal grace period;
- MXL Domain and flow identity;
- shell and deployment-tool usage;
- the web editor's file operations, syntax check, and form, and its refusal
  to write an MXL Domain.

The minimal demonstration uses only flat directories, so it does not need an
MXL writer. Both sides are covered by copying files:

```bash
cp program.sdp /var/lib/nvnmos/sdp-senders/
cp monitor.sdp /var/lib/nvnmos/sdp-receivers/
cp graphics.flow_def.json /var/lib/nvnmos/mxl-senders/
cp monitor.flow_def.json /var/lib/nvnmos/mxl-receivers/

# Resources appear with those filenames as their caller-chosen names.

cp updated-program.sdp /var/lib/nvnmos/sdp-senders/.program.sdp.tmp
mv /var/lib/nvnmos/sdp-senders/.program.sdp.tmp \
   /var/lib/nvnmos/sdp-senders/program.sdp

# The Sender keeps its identity and publishes the new authoritative state.

rm /var/lib/nvnmos/sdp-senders/program.sdp

# The Sender is disabled immediately and removed after the configured grace.
```

A separate demonstration covers an MXL Domain. An MXL writer, configured for
`/dev/shm/studio`, creates `<flow-id>.mxl-flow/flow_def.json`. `nvnmosd-fs`
exposes that flow as a Sender named `studio/<flow-id>`. When the writer
removes the flow, the Sender is disabled and then removed under the same
removal policy. `nvnmosd-fs` does not create the flow.

## 15. Acceptance criteria for the first release

The first release is complete when:

- read-only-active Nodes reject every controller-originated activation before
  changing `/active`;
- normal Nodes retain existing IS-05 behaviour;
- valid SDP and `.flow_def.json` files create Sender and Receiver resources;
- an MXL Domain directory creates one Sender per live flow, and no Sender
  from `domain_def.json` or the shared-memory files;
- a file of the wrong kind in a typed directory does not become a resource;
- relative paths, or `<logical Domain name>/<flow UUID>`, determine identity;
- valid updates preserve NMOS UUIDs;
- invalid replacements preserve the last valid state;
- delete and rapid recreate follow the configured removal policy;
- restart and daemon reconnection converge to the current directories;
- tests cover both file kinds, both resource sides, and a Domain directory.

Directory reconciliation can be used from the shell as soon as those criteria
are met. The web editor in section 11 is the last step of the same work, and
it is complete when the checks in section 13.5 pass.
