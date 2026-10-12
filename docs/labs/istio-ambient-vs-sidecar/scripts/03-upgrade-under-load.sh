#!/usr/bin/env bash
# In-place Helm upgrade 1.30.5 -> 1.31.1 while fortio drives 100 qps over 4
# keep-alive connections in each meshed namespace. Records fortio results per
# namespace plus a timeline of the upgrade steps.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$LAB_DIR/results/upgrade"
NEW=1.31.1
CHARTS="/tmp/istio-${NEW}/manifests/charts"
HUB=(--set global.hub=docker.io/istio --set global.variant=distroless --set hub=docker.io/istio --set variant=distroless)
NFT=(--set global.nativeNftables=true)
DURATION=${DURATION:-300s}
mkdir -p "$OUT"
: > "$OUT/timeline.txt"
mark() { echo "$(date -u +%H:%M:%S.%3N) $*" | tee -a "$OUT/timeline.txt"; }

pids=()
for ns in sidecar ambient ambient-wp; do
  kubectl -n "$ns" exec deploy/client -c fortio -- \
    fortio load -qps 100 -c 4 -t "$DURATION" -json - http://server:8080/echo \
    > "$OUT/$ns.json" 2> "$OUT/$ns.log" &
  pids+=($!)
done
mark "load started ($DURATION, 100 qps, 4 conns) in sidecar ambient ambient-wp"
sleep 20

mark "helm upgrade istio-base"
helm upgrade istio-base "$CHARTS/base" -n istio-system "${HUB[@]}" --wait >/dev/null
mark "helm upgrade istiod"
helm upgrade istiod "$CHARTS/istio-control/istio-discovery" -n istio-system --set profile=ambient "${HUB[@]}" "${NFT[@]}" --wait >/dev/null
mark "istiod done"
sleep 20
mark "helm upgrade istio-cni"
helm upgrade istio-cni "$CHARTS/istio-cni" -n istio-system --set profile=ambient "${HUB[@]}" "${NFT[@]}" --wait >/dev/null
mark "istio-cni done"
sleep 20
mark "helm upgrade ztunnel"
helm upgrade ztunnel "$CHARTS/ztunnel" -n istio-system "${HUB[@]}" --wait >/dev/null
mark "ztunnel done"
kubectl -n istio-system rollout status ds/ztunnel >/dev/null
kubectl -n ambient-wp rollout status deploy/waypoint >/dev/null
mark "ztunnel + waypoint rollouts complete"

wait "${pids[@]}" || true
mark "load finished"

istioctl proxy-status > "$OUT/proxy-status-after.txt" 2>&1 || true
kubectl get pods -A -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName,IMAGES:.spec.containers[*].image,INIT:.spec.initContainers[*].image' \
  | grep -E 'NS|istio-system|sidecar|ambient' > "$OUT/images-after.txt"
kubectl -n istio-system get events --sort-by=.lastTimestamp > "$OUT/istio-system-events.txt"

for ns in sidecar ambient ambient-wp; do
  echo "== $ns"
  jq -r '"requests=\(.DurationHistogram.Count) sockets=\(.SocketCount) codes=\(.RetCodes) max_ms=\(.DurationHistogram.Max*1000|floor) p99_ms=\(.DurationHistogram.Percentiles[]|select(.Percentile==99)|.Value*1000)"' "$OUT/$ns.json"
done | tee "$OUT/summary.txt"
