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
# Did the ambient-wp ServiceEntry (addresses = the endpoint IP) go through the
# waypoint? A waypoint adds `server: istio-envoy` and
# `x-envoy-decorator-operation` to responses; a direct connection adds nothing.
istioctl ztunnel-config service -o json | jq -c '.[] | select(.hostname=="ext-http.lab.internal") | {hostname,vips,waypoint}' \
  | tee -a "$OUT/outbound.txt"
kubectl -n ambient-wp get serviceentry ext-http -o jsonpath='{.status.conditions[0].type}={.status.conditions[0].status} {.status.conditions[0].message}{"\n"}' \
  | sed 's/^/[ambient-wp SE with addresses] /' | tee -a "$OUT/outbound.txt"
for u in "http://ext-http.lab.internal:8080/debug" "http://$EXT_IP:8080/debug"; do
  h=$(kubectl -n ambient-wp exec deploy/client -c fortio -- fortio curl -timeout 3s "$u" 2>&1 \
    | grep -iE '^HTTP/1.1|^server:|^x-envoy-decorator-operation' | tr -d '\r' | paste -sd' ' -)
  echo "[ambient-wp SE with addresses] $u : $h" | tee -a "$OUT/outbound.txt"
done
zt=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=mesh-lab-worker -o name)
kubectl -n istio-system logs "$zt" --since=10s | grep access | grep "dst.addr=$EXT_IP" | tail -1 \
  | sed 's/^/[client-node ztunnel] /' | tee -a "$OUT/outbound.txt" || true

for ns in sidecar ambient ambient-wp; do kubectl -n "$ns" delete serviceentry ext-http; done

# Same external host, but the ServiceEntry has no `addresses`: istiod auto-allocates
# a VIP, ztunnel's DNS proxy answers with it, and the waypoint headers show
# whether the waypoint was in the path. Also call the raw IP with this SE present.
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: ext-http-noaddr
  namespace: ambient-wp
spec:
  hosts: [ext-noaddr.lab.internal]
  ports:
    - number: 8080
      name: http
      protocol: HTTP
  location: MESH_EXTERNAL
  resolution: STATIC
  endpoints:
    - address: $EXT_IP
EOF
sleep 15
kubectl -n ambient-wp get serviceentry ext-http-noaddr -o jsonpath='{.status.addresses[0].value}{"\n"}' \
  | sed 's/^/[ambient-wp SE without addresses] auto-allocated VIP: /' | tee -a "$OUT/outbound.txt"
for u in "http://ext-noaddr.lab.internal:8080/debug" "http://$EXT_IP:8080/debug"; do
  h=$(kubectl -n ambient-wp exec deploy/client -c fortio -- fortio curl -timeout 3s "$u" 2>&1 \
    | grep -iE '^HTTP/1.1|^server:|^x-envoy-decorator-operation' | tr -d '\r' | paste -sd' ' -)
  echo "[ambient-wp SE without addresses] $u : $h" | tee -a "$OUT/outbound.txt"
done
kubectl -n ambient-wp delete serviceentry ext-http-noaddr
helm upgrade istiod "$CHARTS/istio-control/istio-discovery" -n istio-system --set profile=ambient \
  "${HUB[@]}" "${NFT[@]}" --wait >/dev/null
