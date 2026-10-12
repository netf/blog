#!/usr/bin/env bash
# Blast radius of the node-local proxy. All three meshed clients run on
# mesh-lab-worker. Under 100 qps each:
#   A) graceful: kubectl delete the ztunnel pod on that node
#   B) crash:    SIGKILL the ztunnel container (crictl stop -t 0)
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$LAB_DIR/results/ztunnel-failure"
mkdir -p "$OUT"
NS=(sidecar ambient ambient-wp)
NODE=mesh-lab-worker

zt() { kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$NODE -o name; }

run() { # label action...
  local label=$1; shift
  local pids=()
  for ns in "${NS[@]}"; do
    kubectl -n "$ns" exec deploy/client -c fortio -- \
      fortio load -qps 100 -c 4 -t 60s -json - http://server:8080/echo \
      > "$OUT/$label-$ns.json" 2> "$OUT/$label-$ns.log" &
    pids+=($!)
  done
  sleep 15
  echo "$(date -u +%T.%3N) $label: $*" | tee -a "$OUT/timeline.txt"
  "$@"
  wait "${pids[@]}" || true
  for ns in "${NS[@]}"; do
    jq -r --arg l "$label" --arg ns "$ns" '"\($l) \($ns): requests=\(.DurationHistogram.Count) sockets=\(.SocketCount) codes=\(.RetCodes) max_ms=\(.DurationHistogram.Max*1000|floor)"' "$OUT/$label-$ns.json"
    # error window and error kinds, from fortio's structured log
    grep '"level":"err"' "$OUT/$label-$ns.log" | jq -rs --arg l "$label" --arg ns "$ns" '
      select(length > 0) | (map(.ts) | min) as $a | (map(.ts) | max) as $b
      | "  \($l) \($ns): \(length) error log lines between \($a | strftime("%H:%M:%S")) and +\((($b - $a) * 1000 | floor))ms; kinds: \(map(.msg | sub(": lookup.*"; "") | sub("\""; ""; "g")) | unique | join(" | "))"' || true
  done | tee -a "$OUT/summary.txt"
}

graceful() {
  local pod; pod=$(zt)
  kubectl -n istio-system logs -f "$pod" > "$OUT/graceful-old-ztunnel.log" 2>&1 &
  local lp=$!
  kubectl -n istio-system delete "$pod" --wait=true
  kill $lp 2>/dev/null || true
  kubectl -n istio-system rollout status ds/ztunnel
  echo "$(date -u +%T.%3N) graceful: new ztunnel ready" | tee -a "$OUT/timeline.txt"
}

crash() {
  local id pod rc0
  pod=$(zt)
  rc0=$(kubectl -n istio-system get "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')
  id=$(docker exec $NODE crictl ps --name istio-proxy --label io.kubernetes.pod.namespace=istio-system -q)
  docker exec $NODE crictl stop -t 0 "$id"
  until [ "$(kubectl -n istio-system get "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')" -gt "$rc0" ] &&
        kubectl -n istio-system get "$pod" -o jsonpath='{.status.containerStatuses[0].ready}' | grep -q true; do sleep 0.2; done
  echo "$(date -u +%T.%3N) crash: ztunnel container ready again (restartCount=$(kubectl -n istio-system get "$(zt)" -o jsonpath='{.status.containerStatuses[0].restartCount}'))" | tee -a "$OUT/timeline.txt"
}

: > "$OUT/summary.txt"; : > "$OUT/timeline.txt"
kubectl get pods -A -o wide | grep -E "ztunnel|waypoint|client-|server-" | awk "{print \$1, \$2, \$8}" > "$OUT/placement.txt"
run graceful graceful
sleep 10
run crash crash
