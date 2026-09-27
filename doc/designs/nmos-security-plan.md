<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# NMOS control-plane security for libnvnmos — plan

Status: proposed design

Scope: `nvnmos.h` / libnvnmos, the Rust wrapper, `nvnmosd.proto` / nvnmosd, and the way gst-nmos-rs supplies `NodeConfig`. The goal is BCP-003-01 (TLS), IS-10 / BCP-003-02 (authorization), then BCP-003-03 (certificate provisioning).

This is for Nodes that libnvnmos itself hosts.

## 1. Goal

A Node created through the C API, through nvnmosd, or through gst-nmos-rs can:

- serve its NMOS APIs over HTTPS and WSS, with a CA-signed certificate
- register and heartbeat a secure Registry, sending an IS-10 access token
- require an IS-10 access token on the APIs it serves
- obtain and renew that certificate with BCP-003-03 once the TLS listener exists

Unset security configuration keeps today's behaviour: HTTP, no authorization. Existing deployments stay valid.

The daemon's gRPC socket stays a local Unix socket. This plan secures the NMOS HTTP and WebSocket APIs, not that socket.

## 2. What nmos-cpp already does

nmos-cpp implements the behaviour, behind settings and callbacks. libnvnmos does not pass those settings. `NvNmosNodeConfig` has host, port, label, seed, resources, and callbacks. `server::make_settings` in `nvnmos.cpp` fills the corresponding nmos-cpp settings and leaves `server_secure`, `client_secure`, `server_authorization`, and `client_authorization` at their defaults (`false`).

`nmos::experimental::make_node_server` does not start the security threads. `nmos-cpp-node/main.cpp` does, and the callbacks have to be installed on the node implementation **before** `make_node_server`:

- when `server_secure` is set: OCSP response handler, then `ocsp_behaviour_thread`
- when `server_authorization` is set: HTTP and WebSocket token validation handlers, then `authorization_token_issuer_thread`
- when `client_authorization` is set: bearer-token, load/save authorization-client, and private-key handlers, then `authorization_behaviour_thread`
- when the grant is authorization-code: the redirect listener
- when the token endpoint auth method is `private_key_jwt`: the JWKS listener

libnvnmos has to grow that same wiring. Flipping the settings flags alone does not turn security on.

Current nmos-cpp `private_key_jwt` loads RSA keys (`load_rsa_private_keys`). The first increment follows that. ECDSA client assertions wait until nmos-cpp can sign them.

BCP-003-03 is not on nmos-cpp `master`. [sony/nmos-cpp#377](https://github.com/sony/nmos-cpp/pull/377) adds an EST client (open since 2024, refreshed in 2025, CI green, no review yet). This plan adopts that client rather than writing another one. It still only has to produce the PEM files the existing certificate settings load.

## 3. Layering

| Layer | Owns | Does not own |
|-------|------|--------------|
| **nmos-cpp** | TLS listeners, OCSP, IS-10 client and resource-server behaviour | PEM renewal, nvnmos config |
| **libnvnmos** | Map `NvNmosNodeConfig` security fields into nmos-cpp settings; install the callbacks and threads from §2 | Daemon files, GStreamer properties |
| **nvnmosd** | Per-Node security at create time, including PEM paths and the saved IS-10 client record | The Authorization Server |
| **gst-nmos-rs** | Pass a non-secret reference (a profile name) if a pipeline must select one. PEM paths and secrets stay in the daemon configuration | A copy of the certificate store |

Security is fixed when the Node is created. A later `OpenSession` for the same seed does not change it, matching `host_name`, `http_port`, and the rest of `NodeConfig`.

The Authorization Server is a deployed OAuth 2.0 server, configured so its tokens match IS-10. [INFO-002](https://specs.amwa.tv/info-002/), the NMOS security implementation guide, says any OAuth 2.0 or OpenID Connect server can play this role. Its [Authorization Server Setup](https://specs.amwa.tv/info-002/branches/main/docs/Authorization_Server_Setup.html) uses Keycloak as the worked example: client-credentials registration with an initial access token, `x-nmos-*` claims, and DNS-SD as `_nmos-auth._tcp`. nmos-cpp and nvnmosd are the OAuth client and the resource server. nmos-cpp CI turns on `ENABLE_AUTH` in the NMOS Testing Tool, which supplies a mock Authorization Server for those tests; it does not run Keycloak.

## 4. C API

A null `NvNmosSecurityConfig *` on `NvNmosNodeConfig` means insecure, including a zero-initialised config.

The struct maps onto the nmos-cpp settings below rather than inventing a parallel vocabulary. Paths are filesystem paths. The library reads them when the Node is created and when nmos-cpp's load handlers run; it does not copy private keys into the process environment.

### 4.1 BCP-003-01

| nmos-cpp setting | Role |
|------------------|------|
| `server_secure` | HTTPS and WSS listeners |
| `client_secure` | HTTPS and WSS to the Registry, Authorization Server, and OCSP |
| `ca_certificate_file` | PEM CA bundle for those clients |
| `server_certificates[]` | `key_algorithm`, `private_key_file`, `certificate_chain_file` |
| `dh_param_file` | Optional DHE parameters |
| `validate_certificates` | Default true |
| `hsts_max_age`, `hsts_include_sub_domains` | HSTS when `server_secure` is set |

`server_secure` requires at least one server certificate. `client_secure` requires `ca_certificate_file`. OCSP intervals keep nmos-cpp's defaults unless overridden.

Advertised `https` and `wss` URLs follow `client_secure`, not `server_secure` (`http_scheme` / `ws_scheme` in `api_utils.cpp`). `http_port` remains the port published to clients. `proxy_map` can bind the process on a different port.

#### Where TLS terminates

Two deployments are open. Both keep IS-10 validation inside nmos-cpp: `server_authorization` reads the bearer token on the request that reaches the Node, including the WebSocket upgrade. Neither deployment has a mode where the proxy consumes the token and the Node trusts the hop.

| | In-process TLS | TLS-terminating proxy |
|--|--|--|
| Settings | `server_secure` and `client_secure` | `client_secure` true, `server_secure` false. The `server_secure` comment in `settings.h` describes this case |
| Who speaks TLS to clients | The cpprest listener, with OCSP stapling | The proxy. `get_hsts` already leaves HSTS to the proxy when `server_secure` is false |
| Certificate | `server_certificates` loaded by the Node listener | The same PEM paths. The Node listener does not load them. EST still writes the files named by `server_certificates`, and the proxy reads those files |
| Hop behind the proxy | None | Plain HTTP and WebSocket, reachable only from the proxy |

The proxy forwards `Authorization`, `X-Forwarded-Host`, and the WebSocket upgrade. `get_host_port` already prefers `X-Forwarded-Host`. It does not read `X-Forwarded-Proto`; `query_api.cpp` and `logging_api.cpp` note that and then take the scheme from `client_secure`. A deployment that is HTTPS for every client can live with that.

nmos-cpp CI does not prove the proxy deployment. The authorization jobs set `ENABLE_HTTPS` on the NMOS Testing Tool and speak TLS to the Node directly. There is no nginx, Envoy, or similar in front of a `server_secure=false` Node, so cipher, TLS 1.3, HSTS, WebSocket upgrade, and header forwarding are unproven for that layout.

Work in nmos-cpp, whichever deployment is chosen:

- A CI job that runs the BCP-003-01 suite (including testssl) against the process clients actually reach. For the proxy deployment that process is the proxy, with the Node at `server_secure=false`, and the job must also PATCH Connection with a bearer token through the proxy and open an authorized WebSocket.
- Decide whether `X-Forwarded-Proto` is required. Today the scheme is only the `client_secure` setting.

### 4.2 IS-10 / BCP-003-02

| nmos-cpp setting | Role |
|------------------|------|
| `server_authorization` | Require a bearer token on the Node's APIs |
| `client_authorization` | Send a bearer token to protected Registries and Nodes |
| `authorization_flow` | `client_credentials` for this library. `authorization_code` is accepted on the C API for an application that can complete a redirect; nvnmosd and gst-nmos-rs do not use it |
| `token_endpoint_auth_method` | `private_key_jwt` (RSA, see §2) or `client_secret_basic` |
| `authorization_scopes` | `registration` for a Node that registers. Further scopes only if this Node calls other Nodes' APIs |
| `initial_access_token` | Closed dynamic registration, when the Authorization Server requires one |
| `authorization_address`, `authorization_port`, `authorization_version`, `authorization_selector` | Fixed Authorization Server. Empty uses DNS-SD, alongside the existing Registration and System fields |
| `jwks_uri_port` | Local JWKS listener for `private_key_jwt` |
| `authorization_redirect_port` | Only for `authorization_code` |

The load/save authorization-client handlers need a per-Node path, supplied here, so a restart presents the same `client_id` instead of registering again.

Token validation, refresh, and public-key fetch stay inside nmos-cpp's threads from §2.

### 4.3 BCP-003-03

Not part of the first TLS or authorization increments.

The EST client is the one in [sony/nmos-cpp#377](https://github.com/sony/nmos-cpp/pull/377), once that is merged. It discovers the EST server, enrolls with the manufacturer client certificate, and writes PEM files: the CA bundle to `ca_certificate_file`, and each server key and chain to the matching `server_certificates` entry (`make_save_ca_certificates_handler`, `make_save_rsa_server_certificate_handler`, `make_save_ecdsa_server_certificate_handler`). Renewal follows BCP-003-03 (after 80% of the certificate lifetime, via `/simplereenroll`) and overwrites those files. The pull request does not reload a listener or notify a proxy.

That file write is the same for both deployments in §4.1. What happens after the write differs:

- **In-process TLS.** The listener uses those files only when its SSL context callback runs again. `make_listener_ssl_context_callback` loads the PEMs when invoked. Nothing in the EST callbacks invokes it, and nothing in CI shows whether cpprest invokes it per handshake or once at listen. Until that is known, renewal restarts the Node inside the daemon and keeps the same seed and ids.
- **TLS-terminating proxy.** The proxy must be aimed at the same paths and must reload when they change. The pull request has no such hook. A proxy that watches the files can do this without an nmos-cpp change; a callback after a successful save would make the reload explicit. Neither is implemented or run in CI.

The pull request's own CI is the existing build-and-test matrix, which does not start an EST server and has no EST unit tests. The NMOS Testing Tool has no BCP-003-03 suite. Before this plan depends on the pull request, nmos-cpp needs a job that enrolls against a local EST server, checks the PEM files, renews, and then serves HTTPS from whichever deployment §4.1 selects. The in-process case is the BCP-003-01 suite against the Node after enroll. The proxy case is that suite against the proxy after it has reloaded the new files.

## 5. nvnmosd

`NodeConfig` in `nvnmosd.proto` gains an optional security message with the same contents as §4. Unset means insecure.

Daemon configuration is the normal place for PEM paths and the IS-10 client-record directory, keyed by Node seed, with a process-wide default. An RPC that sets security fields uses those fields for that create. gst-nmos-rs pipelines then stay free of private-key paths.

The experimental Settings API (`NVNMOS_EXPERIMENTAL_SETTINGS`) remains a debug backdoor. It is not the configuration mechanism for certificates or authorization.

## 6. gst-nmos-rs

Element properties already carry the non-secret Node identity (`node-seed`, `host-name`, `http-port`, `registration-url`). Certificate paths and client secrets do not join them.

A Node created by the first session picks up the daemon's security configuration for that seed. An optional element field may name a daemon-side profile when one pipeline host runs Nodes under different certificates. The profile name is not a filesystem path.

`registration-url` of `https://...` implies `client_secure` for that Node. The CA bundle still comes from the daemon configuration.

## 7. Order of work

1. **TLS.** C API, `make_settings`, OCSP thread wiring, proto, daemon configuration. Choose in-process TLS or a terminating proxy (§4.1) before treating `server_secure` as the only supported layout. A Node registers an HTTPS Registry, and the process clients reach passes the nmos-testing BCP-003-01 suite.
2. **Authorization.** Resource-server validation and the client-credentials client, with a persisted `client_id`. Cover a protected Registry and a protected Connection API. Authorization-code redirect stays on the C API only.
3. **Certificate provisioning.** EST enroll and renew into the PEM paths from step 1, using [sony/nmos-cpp#377](https://github.com/sony/nmos-cpp/pull/377). The pull request's missing CI (§4.3) lands with that work. Advertise BCP-003-03 on the Node `/self` tags once enroll works and the chosen TLS deployment is serving the new certificate.

Each step is usable without the later ones. Step 1 is file-based certificates. Step 3 replaces the files.

## 8. Tests

- Insecure Node still comes up with a zero-initialised config.
- `server_secure` without a certificate fails at create, with a logged reason.
- HTTPS Node API and Connection API against the BCP-003-01 test suite.
- Client-credentials registration against an IS-10 Registry, then a second process start reuses the saved client record.
- A Connection PATCH without a token is rejected when `server_authorization` is set, and succeeds with a token whose scope allows it.
- EST enroll is a later test, against a local EST server, once step 3 exists. It includes the reload of whichever process terminates TLS.

## 9. Open points

- In-process TLS or a terminating proxy (§4.1). The C API can express both with the existing settings; the unproven part is nmos-cpp CI, not a new nvnmos setting.
- Confirm when nmos-cpp rebuilds the listener SSL context, and whether renewal can avoid recreating the Node (§4.3). For the proxy, confirm reload of the proxy from the PEM paths the EST callbacks overwrite.
- RSA-only `private_key_jwt` in current nmos-cpp (§2). Server certificates may still be ECDSA, RSA, or both, as BCP-003-01 allows; the client assertion is the RSA constraint.
- Per-seed certificates versus one certificate with many SANs when several Nodes share a hostname. The configuration allows either; the daemon default is per seed.
