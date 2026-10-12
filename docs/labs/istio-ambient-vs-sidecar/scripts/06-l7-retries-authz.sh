#!/usr/bin/env bash
# L7 semantics per mode:
#  - retries: fortio returns 503 for ~50% of requests (?status=503:50); measure
#    what the client sees with Istio's default retry policy and with an explicit
#    VirtualService retry policy.
#  - authz: an AuthorizationPolicy that DENYs GET /debug only.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$LAB_DIR/results/l7"
mkdir -p "$OUT"
MESH=(sidecar ambient ambient-wp)

load503() { # label
  for ns in "${MESH[@]}"; do
    kubectl -n "$ns" exec deploy/client -c fortio -- \
      fortio load -qps 100 -c 4 -n 2000 -json - "http://server:8080/echo?status=503:50" 2>/dev/null \
      | jq -c --arg ns "$ns" --arg l "$1" '{label:$l, ns:$ns, codes:.RetCodes, p50_ms:(.DurationHistogram.Percentiles[0].Value*1000), p99_ms:(.DurationHistogram.Percentiles[]|select(.Percentile==99)|.Value*1000)}'
  done | tee -a "$OUT/retries.jsonl"
}

: > "$OUT/retries.jsonl"
load503 "no VirtualService (Istio default retry policy)"

for ns in "${MESH[@]}"; do
  kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: server
  namespace: $ns
spec:
  hosts: [server.$ns.svc.cluster.local]
  http:
    - route:
        - destination:
            host: server.$ns.svc.cluster.local
      retries:
        attempts: 5
        retryOn: 5xx
        perTryTimeout: 1s
EOF
done
sleep 10
load503 "VirtualService retries attempts=5 retryOn=5xx"

# Explicitly disable retries to measure the raw error rate through each proxy.
for ns in "${MESH[@]}"; do
  kubectl -n "$ns" patch virtualservice server --type=json -p='[{"op":"replace","path":"/spec/http/0/retries","value":{"attempts":0}}]'
done
sleep 10
load503 "VirtualService retries attempts=0"
for ns in "${MESH[@]}"; do kubectl -n "$ns" delete virtualservice server; done

# Authorization: deny GET /debug, allow everything else.
: > "$OUT/authz.txt"
for ns in "${MESH[@]}"; do
  if [ "$ns" = ambient-wp ]; then
    # Policies for a waypoint attach to the Service via targetRefs.
    target='targetRefs: [{kind: Service, group: "", name: server}]'
  else
    target='selector: {matchLabels: {app: server}}'
  fi
  kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-debug
  namespace: $ns
spec:
  $target
  action: DENY
  rules:
    - to:
        - operation:
            paths: ["/debug"]
EOF
done
sleep 10
for ns in "${MESH[@]}"; do
  for path in /echo /debug; do
    code=$(kubectl -n "$ns" exec deploy/client -c fortio -- fortio curl -timeout 3s "http://server:8080$path" 2>&1 \
      | grep -oE 'HTTP/1.1 [0-9]+|connection reset by peer|EOF|i/o timeout' | head -1 || true)
    echo "$ns GET $path -> ${code:-no response}" | tee -a "$OUT/authz.txt"
  done
done
kubectl -n ambient get authorizationpolicy deny-debug -o yaml > "$OUT/authz-ambient-status.yaml"
for ns in "${MESH[@]}"; do kubectl -n "$ns" delete authorizationpolicy deny-debug; done
