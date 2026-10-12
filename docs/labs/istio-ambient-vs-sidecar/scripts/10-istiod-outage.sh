#!/usr/bin/env bash
# Control-plane outage: scale istiod to 0, then
#  1) check existing traffic still flows in each mode,
#  2) scale each server to 2 replicas and check whether the new pod is created
#     and can serve traffic,
#  3) restore istiod.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$LAB_DIR/results/istiod-outage"
mkdir -p "$OUT"
NS=(sidecar ambient ambient-wp)
log() { echo "$(date -u +%T) $*" | tee -a "$OUT/outage.txt"; }
: > "$OUT/outage.txt"

kubectl -n istio-system scale deploy/istiod --replicas=0
kubectl -n istio-system wait --for=delete pod -l app=istiod --timeout=120s || true
log "istiod scaled to 0"
sleep 10

for ns in "${NS[@]}"; do
  r=$(kubectl -n "$ns" exec deploy/client -c fortio -- fortio load -qps 50 -c 2 -n 200 -json - http://server:8080/echo 2>/dev/null | jq -c .RetCodes)
  log "$ns existing pods, istiod down: $r"
done

for ns in "${NS[@]}"; do kubectl -n "$ns" scale deploy/server --replicas=2; done
sleep 60
for ns in "${NS[@]}"; do
  log "$ns pods after scale-up with istiod down:"
  kubectl -n "$ns" get pods -l app=server -o wide 2>&1 | tee -a "$OUT/outage.txt"
  kubectl -n "$ns" get rs -l app=server -o json | jq -r '.items[] | select(.spec.replicas>0) | .status.conditions[]? | "  rs condition: \(.type) \(.message)"' | tee -a "$OUT/outage.txt"
  newpod=$(kubectl -n "$ns" get pods -l app=server --sort-by=.metadata.creationTimestamp -o name | tail -1)
  ip=$(kubectl -n "$ns" get "$newpod" -o jsonpath='{.status.podIP}')
  if [ -n "$ip" ]; then
    r=$(kubectl -n "$ns" exec deploy/client -c fortio -- fortio load -qps 20 -c 1 -n 20 -timeout 3s -json - "http://$ip:8080/echo" 2>/dev/null | jq -c .RetCodes)
    log "$ns client -> NEW pod $newpod ($ip) directly: $r"
  fi
done
kubectl -n istio-system get events --sort-by=.lastTimestamp 2>/dev/null | tail -5 >> "$OUT/outage.txt"
kubectl get events -A --field-selector reason=FailedCreate -o custom-columns=NS:.metadata.namespace,MSG:.message 2>/dev/null | tail -5 | tee -a "$OUT/outage.txt"

kubectl -n istio-system scale deploy/istiod --replicas=1
kubectl -n istio-system rollout status deploy/istiod
log "istiod restored"
sleep 60
for ns in "${NS[@]}"; do
  log "$ns pods 60s after istiod restored:"
  kubectl -n "$ns" get pods -l app=server -o wide 2>&1 | tee -a "$OUT/outage.txt"
done
for ns in "${NS[@]}"; do kubectl -n "$ns" scale deploy/server --replicas=1; done
