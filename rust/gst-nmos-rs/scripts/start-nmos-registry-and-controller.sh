#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Start an NMOS Registry (nmos-cpp) and NMOS Controller (controller-ui) in Docker,
# then wait until Ctrl+C.
#
# Images (override as needed):
#   NMOS_REGISTRY_IMAGE   default rhastie/nmos-cpp:latest
#   CONTROLLER_UI_IMAGE   default nvcr.io/nvidia/holoscan-for-media/controller-ui:0.7.0
#
# Ports:
#   DEMO_REGISTRY_HTTP_PORT     default 3211
#   DEMO_CONTROLLER_UI_PORT     default 3000
#
# Registry Docker network:
#   DEMO_REGISTRY_DOCKER_NETWORK  bridge (default) or host
#   DEMO_REGISTRY_HOSTNAME        default nmos-registry (bridge only)
#
# On bridge, the Registry advertises its Registration, Query and System APIs
# with an SRV target of <DEMO_REGISTRY_HOSTNAME>.local, so this script adds an
# /etc/hosts entry for it (sudo) to keep Node registration prompt.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
require_cmd docker docker
require_cmd curl curl

REGISTRY_IMAGE=${NMOS_REGISTRY_IMAGE:-rhastie/nmos-cpp:latest}
CONTROLLER_IMAGE=${CONTROLLER_UI_IMAGE:-nvcr.io/nvidia/holoscan-for-media/controller-ui:0.7.0}
REGISTRY_HTTP_PORT=${DEMO_REGISTRY_HTTP_PORT:-3211}
REGISTRY_WS_PORT=$((REGISTRY_HTTP_PORT + 1))
CONTROLLER_PORT=${DEMO_CONTROLLER_UI_PORT:-3000}
REGISTRY_NET=${DEMO_REGISTRY_DOCKER_NETWORK:-bridge}
REGISTRY_HOSTNAME=${DEMO_REGISTRY_HOSTNAME:-nmos-registry}
REGISTRY_NAME=${DEMO_REGISTRY_CONTAINER:-gst-nmos-rs-registry}
CONTROLLER_NAME=${DEMO_CONTROLLER_CONTAINER:-gst-nmos-rs-controller-ui}

WORKDIR=$(mktemp -d /tmp/gst-nmos-rs-talk.XXXXXX)
cleanup() {
    docker stop "$CONTROLLER_NAME" "$REGISTRY_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTROLLER_NAME" "$REGISTRY_NAME" >/dev/null 2>&1 || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

docker stop "$CONTROLLER_NAME" "$REGISTRY_NAME" >/dev/null 2>&1 || true
docker rm "$CONTROLLER_NAME" "$REGISTRY_NAME" >/dev/null 2>&1 || true

cat >"$WORKDIR/registry.json" <<EOF
{
  "label": "gst-nmos-rs-talk-registry",
  "http_port": ${REGISTRY_HTTP_PORT}
}
EOF

cat >"$WORKDIR/controller-config.json" <<EOF
{
  "NMOSRegistryBaseUrl": "http://127.0.0.1:${REGISTRY_HTTP_PORT}",
  "ConnectionBridgeMode": "disabled"
}
EOF

# A locally built image (e.g. CONTROLLER_UI_IMAGE=controller-ui:prod) has no
# registry to pull from, so only pull tags that are not already present.
ensure_image() {
    local image=$1
    if docker image inspect "$image" >/dev/null 2>&1; then
        echo "Using local image ${image}"
        return 0
    fi
    echo "Pulling ${image} ..."
    docker pull "$image"
}

# Nodes resolve the Registry's SRV target, <hostname>.local, with getaddrinfo,
# because the Avahi compatibility layer has no DNSServiceGetAddrInfo. Where
# libnss-mdns is slow, that lookup dominates the time for a Node to register,
# so point the name at the container address in /etc/hosts, which is consulted
# first. The SRV target keeps its trailing dot, and /etc/hosts names are matched
# literally, so both forms are listed. The container address changes each run,
# hence the marker comment.
ensure_registry_host_entry() {
    local name=$1
    local ip
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$REGISTRY_NAME")
    if [[ -z "$ip" ]]; then
        echo "[warn] could not determine the ${REGISTRY_NAME} address; skipping /etc/hosts" >&2
        return 0
    fi
    local marker="# ${REGISTRY_NAME}"
    local entry="${ip} ${name}.local. ${name}.local ${name} ${marker}"
    if grep -qxF "$entry" /etc/hosts; then
        return 0
    fi
    local hosts="$WORKDIR/hosts"
    grep -vF "$marker" /etc/hosts >"$hosts" || true
    printf '%s\n' "$entry" >>"$hosts"
    if sudo -n cp "$hosts" /etc/hosts 2>/dev/null || { [[ -t 0 ]] && sudo cp "$hosts" /etc/hosts; }; then
        echo "Added to /etc/hosts: ${entry}"
    else
        echo "[warn] /etc/hosts not updated, so each Node takes ~10 s to discover the Registry" >&2
        echo "[warn] add this line by hand: ${entry}" >&2
    fi
}

ensure_image "$REGISTRY_IMAGE"
ensure_image "$CONTROLLER_IMAGE"

registry_args=(
    -d --name "$REGISTRY_NAME"
    -v "$WORKDIR/registry.json:/home/registry.json:ro"
    -e RUN_NODE=FALSE
)
case "$REGISTRY_NET" in
    host)
        registry_args+=(--network host)
        ;;
    bridge)
        registry_args+=(
            --network bridge
            --hostname "$REGISTRY_HOSTNAME"
            -p "${REGISTRY_HTTP_PORT}:${REGISTRY_HTTP_PORT}"
            -p "${REGISTRY_WS_PORT}:${REGISTRY_WS_PORT}"
        )
        ;;
    *)
        echo "[error] DEMO_REGISTRY_DOCKER_NETWORK must be bridge or host" >&2
        exit 2
        ;;
esac

docker run "${registry_args[@]}" "$REGISTRY_IMAGE"

docker run -d --name "$CONTROLLER_NAME" \
    -p "${CONTROLLER_PORT}:80" \
    -v "$WORKDIR/controller-config.json:/usr/share/nginx/html/config/config.json:ro" \
    "$CONTROLLER_IMAGE"

echo "Waiting for Registry Query API on 127.0.0.1:${REGISTRY_HTTP_PORT} ..."
ok=0
for _ in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:${REGISTRY_HTTP_PORT}/x-nmos/query/v1.3/" >/dev/null; then
        ok=1
        break
    fi
    sleep 1
done
if [[ "$ok" -ne 1 ]]; then
    echo "[error] Registry did not become ready. docker logs ${REGISTRY_NAME}:" >&2
    docker logs "$REGISTRY_NAME" >&2 || true
    exit 1
fi

if [[ "$REGISTRY_NET" == bridge ]]; then
    ensure_registry_host_entry "$REGISTRY_HOSTNAME"
fi

cat <<EOF

Registry Query API:  http://127.0.0.1:${REGISTRY_HTTP_PORT}/x-nmos/query/v1.3
Controller UI:       http://127.0.0.1:${CONTROLLER_PORT}

Nodes discover this Registry via DNS-SD (no registration-url). Ctrl+C stops
both containers.
EOF

# Keep mounts alive until Ctrl+C (WORKDIR is removed in the EXIT trap).
while true; do
    sleep 3600
done
