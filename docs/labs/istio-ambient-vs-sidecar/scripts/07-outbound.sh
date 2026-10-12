#!/usr/bin/env bash
# Outbound to a destination outside the mesh: a fortio container on the Kind
# Docker network (not a pod). Tested with ALLOW_ANY, REGISTRY_ONLY, and
# REGISTRY_ONLY plus a ServiceEntry.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$LAB_DIR/results/outbound"
CHARTS=/tmp/istio-1.31.1/manifests/charts
HUB=(--set global.hub=docker.io/istio --set global.variant=distroless --set hub=docker.io/istio --set variant=distroless)
NFT=(--set global.nativeNftables=true)
mkdir -p "$OUT"
NS=(baseline sidecar ambient ambient-wp)

docker rm -f ext-http >/dev/null 2>&1 || true
docker run -d --name ext-http --network kind fortio/fortio:1.76.0 server >/dev/null
EXT_IP=$(docker inspect ext-http -f '{{.NetworkSettings.Networks.kind.IPAddress}}')
echo "external server at $EXT_IP:8080" | tee "$OUT/outbound.txt"

probe() { # label
  for ns in "${NS[@]}"; do
    r=$(kubectl -n "$ns" exec deploy/client -c fortio -- fortio curl -timeout 3s "http://$EXT_IP:8080/echo" 2>&1 \
      | grep -oE 'HTTP/1.1 [0-9]+|connection reset by peer|EOF|i/o timeout|refused' | head -1 || true)
    echo "[$1] $ns -> $EXT_IP:8080 : ${r:-no response}" | tee -a "$OUT/outbound.txt"
  done
}

probe "ALLOW_ANY (default)"

helm upgrade istiod "$CHARTS/istio-control/istio-discovery" -n istio-system --set profile=ambient \
  "${HUB[@]}" "${NFT[@]}" --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY --wait >/dev/null
sleep 20
probe "REGISTRY_ONLY"

for ns in sidecar ambient ambient-wp; do
  kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: ext-http
  namespace: $ns
spec:
  hosts: [ext-http.lab.internal]
  addresses: [$EXT_IP/32]
  ports:
    - number: 8080
      name: http
      protocol: HTTP
  location: MESH_EXTERNAL
  resolution: STATIC
  endpoints:
    - address: $EXT_IP
EOF
done
sleep 15
probe "REGISTRY_ONLY + ServiceEntry"
kubectl -n ambient-wp get serviceentry ext-http -o jsonpath='{.metadata.labels}{"\n"}{.status}{"\n"}' >> "$OUT/outbound.txt" || true
# Which proxy served the ServiceEntry in ambient-wp: look for waypoint headers.
kubectl -n ambient-wp exec deploy/client -c fortio -- fortio curl "http://$EXT_IP:8080/debug" 2>&1 \
  | grep -iE '^server:|x-envoy' | sed 's/^/[ambient-wp SE headers] /' | tee -a "$OUT/outbound.txt" || true

for ns in sidecar ambient ambient-wp; do kubectl -n "$ns" delete serviceentry ext-http; done
helm upgrade istiod "$CHARTS/istio-control/istio-discovery" -n istio-system --set profile=ambient \
  "${HUB[@]}" "${NFT[@]}" --wait >/dev/null
