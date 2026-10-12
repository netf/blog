#!/usr/bin/env bash
# Creates the Kind cluster and installs Istio (ambient profile) with Helm.
# The ambient profile still installs the sidecar injector, so one control plane
# serves sidecar namespaces and ambient namespaces side by side.
#
# Usage: ./01-cluster-and-istio.sh [istio-version]   (default 1.30.5)
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ISTIO_VERSION="${1:-1.30.5}"
CHARTS="/tmp/istio-${ISTIO_VERSION}/manifests/charts"
GATEWAY_API_VERSION=v1.5.1
# The charts default to registry.istio.io; the lab VM could only reach Docker Hub.
# The lab VM kernel has no ipset support (`ipset create` -> EINVAL), which the
# default iptables backend of the ambient CNI agent needs. Native nftables mode
# avoids ipset. It is set on istiod too so sidecar redirection uses the same backend.
NFT=(--set global.nativeNftables=true)
HUB=(--set global.hub=docker.io/istio --set global.variant=distroless --set hub=docker.io/istio --set variant=distroless)

kind get clusters | grep -qx mesh-lab || kind create cluster --config "$LAB_DIR/kind-config.yaml"

kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 ||
  kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

helm upgrade --install istio-base "$CHARTS/base" -n istio-system --create-namespace "${HUB[@]}" --wait
helm upgrade --install istiod "$CHARTS/istio-control/istio-discovery" -n istio-system \
  --set profile=ambient "${HUB[@]}" "${NFT[@]}" --wait
helm upgrade --install istio-cni "$CHARTS/istio-cni" -n istio-system \
  --set profile=ambient "${HUB[@]}" "${NFT[@]}" --wait
helm upgrade --install ztunnel "$CHARTS/ztunnel" -n istio-system "${HUB[@]}" --wait

kubectl -n istio-system get pods -o wide
