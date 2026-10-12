#!/usr/bin/env bash
# Finishing a sidecar upgrade means restarting every injected pod. This rolls the
# server Deployment in every namespace under 100 qps, so the sidecar cost can be
# compared with the same application rollout in the other modes, then restarts
# the clients so every sidecar runs the new proxy.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$LAB_DIR/results/restart"
mkdir -p "$OUT"
NS=(baseline sidecar ambient ambient-wp)

pids=()
for ns in "${NS[@]}"; do
  kubectl -n "$ns" exec deploy/client -c fortio -- \
    fortio load -qps 100 -c 4 -t 60s -json - http://server:8080/echo \
    > "$OUT/$ns.json" 2> "$OUT/$ns.log" &
  pids+=($!)
done
sleep 10
for ns in "${NS[@]}"; do kubectl -n "$ns" rollout restart deploy/server; done
for ns in "${NS[@]}"; do kubectl -n "$ns" rollout status deploy/server --timeout=120s; done
wait "${pids[@]}" || true

for ns in "${NS[@]}"; do
  echo "== $ns"
  jq -r '"requests=\(.DurationHistogram.Count) sockets=\(.SocketCount) codes=\(.RetCodes) max_ms=\(.DurationHistogram.Max*1000|floor)"' "$OUT/$ns.json"
done | tee "$OUT/summary.txt"

kubectl -n sidecar rollout restart deploy/client
kubectl -n sidecar rollout status deploy/client --timeout=120s
istioctl proxy-status | tee "$OUT/proxy-status-after-restart.txt"
