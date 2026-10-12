#!/usr/bin/env bash
# Control-plane outage: scale istiod to 0, then
#  1) check existing traffic still flows in each mode,
#  2) scale each server to 2 replicas: is the new pod created, Ready, reachable?
#  3) restore istiod and probe the new pods again.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$LAB_DIR/results/istiod-outage"
mkdir -p "$OUT"
NS=(sidecar ambient ambient-wp)
log() { echo "$(date -u +%T) $*" | tee -a "$OUT/outage.txt"; }
codes() { # ns url n
  kubectl -n "$1" exec deploy/client -c fortio -- fortio load -qps 20 -c 1 -n "$3" -timeout 2s -json - "$2" 2>"$OUT/.err" | jq -c .RetCodes
}
errkinds() { grep '"level":"err"' "$OUT/.err" | jq -r '.err // .msg' | sed 's/[0-9.]*:[0-9]*->/X->/; s/:[0-9]\{4,5\}/:PORT/g' | sort | uniq -c | head -3; }
: > "$OUT/outage.txt"
declare -A NEWPOD NEWIP

kubectl -n istio-system scale deploy/istiod --replicas=0
kubectl -n istio-system wait --for=delete pod -l app=istiod --timeout=120s || true
log "istiod scaled to 0"
sleep 10

for ns in "${NS[@]}"; do
  log "$ns existing pods via Service, istiod down: $(codes "$ns" http://server:8080/echo 200)"
done

for ns in "${NS[@]}"; do kubectl -n "$ns" scale deploy/server --replicas=2; done
sleep 60
for ns in "${NS[@]}"; do
  log "$ns server pods 60s after scale-up to 2 (istiod down):"
  kubectl -n "$ns" get pods -l app=server -o wide --sort-by=.metadata.creationTimestamp | tee -a "$OUT/outage.txt"
  kubectl -n "$ns" get rs -l app=server -o json \
    | jq -r '.items[] | select(.spec.replicas>0) | .status.conditions[]? | "  rs condition: \(.type): \(.message[0:220])"' | tee -a "$OUT/outage.txt"
  if [ "$(kubectl -n "$ns" get pods -l app=server --no-headers | wc -l)" -lt 2 ]; then
    log "$ns: no second pod was created"
    continue
  fi
  NEWPOD[$ns]=$(kubectl -n "$ns" get pods -l app=server --sort-by=.metadata.creationTimestamp -o name | tail -1)
  NEWIP[$ns]=$(kubectl -n "$ns" get "${NEWPOD[$ns]}" -o jsonpath='{.status.podIP}')
  log "$ns client -> new pod ${NEWPOD[$ns]} (${NEWIP[$ns]}) by pod IP: $(codes "$ns" "http://${NEWIP[$ns]}:8080/echo" 20)"
  errkinds | sed 's/^/    /' | tee -a "$OUT/outage.txt"
  log "$ns client -> Service (2 endpoints in k8s, istiod down): $(codes "$ns" http://server:8080/echo 100)"
done
zt=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=mesh-lab-worker2 -o name)
log "server-node ztunnel log lines mentioning the new ambient pod:"
kubectl -n istio-system logs "$zt" --since=200s | grep -E "${NEWIP[ambient]:-none}|${NEWPOD[ambient]#pod/}" | grep -vE "^\s*$" \
  | cut -c1-300 | sort -u -k3 | head -5 | tee -a "$OUT/outage.txt" || true

kubectl -n istio-system scale deploy/istiod --replicas=1
kubectl -n istio-system rollout status deploy/istiod
log "istiod restored"
sleep 30
for ns in "${NS[@]}"; do
  if [ -n "${NEWIP[$ns]:-}" ]; then
    log "$ns client -> new pod by pod IP, 30s after restore: $(codes "$ns" "http://${NEWIP[$ns]}:8080/echo" 20)"
  else
    log "$ns server pods 30s after restore: $(kubectl -n "$ns" get pods -l app=server --no-headers | wc -l)"
  fi
done
sleep 60
for ns in "${NS[@]}"; do
  log "$ns server pods 90s after restore: $(kubectl -n "$ns" get pods -l app=server --no-headers | awk '{print $1" "$2" "$3}' | tr '\n' ';')"
done
for ns in "${NS[@]}"; do kubectl -n "$ns" scale deploy/server --replicas=1; done
rm -f "$OUT/.err"
