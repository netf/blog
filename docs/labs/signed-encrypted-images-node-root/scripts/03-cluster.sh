#!/usr/bin/env bash
# Kind cluster (1 cp + 2 workers) plus a local registry on the kind network that
# both the host and the nodes can reach. Follows the kind "local registry"
# pattern; registry pinned by digest.
set -euo pipefail
export PATH="$HOME/bin:$PATH"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
REG=kind-registry
REG_PORT=5000
REG_IMAGE=registry:2.8.3

docker inspect -f '{{.State.Running}}' "$REG" 2>/dev/null | grep -q true || \
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --name "$REG" "$REG_IMAGE"

kind get clusters | grep -qx supply || kind create cluster --config "$HERE/kind-config.yaml" --wait 120s

docker network connect kind "$REG" 2>/dev/null || true

for n in $(kind get nodes --name supply); do
  docker exec "$n" mkdir -p /etc/containerd/certs.d/kind-registry:5000
  docker exec -i "$n" tee /etc/containerd/certs.d/kind-registry:5000/hosts.toml >/dev/null <<TOML
server = "http://kind-registry:5000"
[host."http://kind-registry:5000"]
  capabilities = ["pull", "resolve"]
TOML
done

"$HERE/scripts/02b-host-iptables-fix.sh"
kubectl get nodes -o wide
