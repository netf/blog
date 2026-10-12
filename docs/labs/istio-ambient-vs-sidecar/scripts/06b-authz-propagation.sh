#!/usr/bin/env bash
# How long after `kubectl apply` an AuthorizationPolicy (DENY GET /debug) is
# actually enforced, per mode, and what ztunnel-only enforcement does with an
# HTTP-only DENY rule. Polls once per second with a fresh fortio process
# (new client->proxy connection each time; proxy->proxy pools may be reused).
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$LAB_DIR/results/l7"
mkdir -p "$OUT"
ROUNDS=${ROUNDS:-3}

policy() { # ns
  local target='selector: {matchLabels: {app: server}}'
  [ "$1" = ambient-wp ] && target='targetRefs: [{kind: Service, group: "", name: server}]'
  cat <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-debug
  namespace: $1
spec:
  $target
  action: DENY
  rules:
    - to:
        - operation:
            paths: ["/debug"]
EOF
}
l4policy() {
  cat <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-client-l4
  namespace: ambient
spec:
  selector: {matchLabels: {app: server}}
  action: DENY
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/ambient/sa/client"]
EOF
}
probe() { # ns path [pod]
  local target=${3:-deploy/client} r
  r=$(kubectl -n "$1" exec "$target" -c fortio -- fortio curl -timeout 2s "http://server:8080$2" 2>&1 \
    | grep -oE 'HTTP/1.1 [0-9]+|connection reset by peer|EOF|i/o timeout' | head -1 || true)
  echo "${r:-none}"
}

: > "$OUT/authz-propagation.txt"
for ns in sidecar ambient-wp ambient; do
  for r in $(seq 1 "$ROUNDS"); do
    before_echo=$(probe "$ns" /echo); before_debug=$(probe "$ns" /debug)
    policy "$ns" | kubectl apply -f - >/dev/null 2>&1
    t0=$(date +%s.%N)
    first=""
    for _ in $(seq 1 90); do
      d=$(probe "$ns" /debug)
      if [ "$d" != "HTTP/1.1 200" ]; then first="$d"; break; fi
      sleep 1
    done
    t1=$(date +%s.%N)
    sleep 2
    after_echo=$(probe "$ns" /echo); after_debug=$(probe "$ns" /debug)
    printf '%s round %s: before [/echo %s, /debug %s] -> /debug became "%s" after %.1fs; 2s later [/echo %s, /debug %s]\n' \
      "$ns" "$r" "$before_echo" "$before_debug" "${first:-still 200 after 90 polls}" "$(echo "$t1 - $t0" | bc)" "$after_echo" "$after_debug" \
      | tee -a "$OUT/authz-propagation.txt"
    kubectl -n "$ns" delete authorizationpolicy deny-debug >/dev/null
    for _ in $(seq 1 90); do [ "$(probe "$ns" /debug)" = "HTTP/1.1 200" ] && break; sleep 1; done
    sleep 3
  done
done
