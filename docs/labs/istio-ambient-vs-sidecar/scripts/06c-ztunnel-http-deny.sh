#!/usr/bin/env bash
# What ztunnel-only enforcement does with an HTTP-only DENY rule, compared with
# an L4-only DENY rule. Run after 06b-authz-propagation.sh.
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
probe() { # ns path [pod container]
  local target=${3:-deploy/client} ctr=${4:-fortio} r
  r=$(kubectl -n "$1" exec "$target" -c "$ctr" -- fortio curl -timeout 2s "http://server:8080$2" 2>&1 \
    | grep -oE 'HTTP/1.1 [0-9]+|connection reset by peer|EOF|i/o timeout' | head -1 || true)
  echo "${r:-none}"
}

: > "$OUT/authz-ztunnel-http-deny.txt"
# ztunnel-only sanity checks: the HTTP-only DENY from a brand-new pod (no pooled
# HBONE connection), the status istiod writes on that policy, what ztunnel
# received, and an L4-only DENY (by principal) proving ztunnel enforces policy.
kubectl -n ambient delete pod fresh --ignore-not-found >/dev/null
kubectl -n ambient run fresh --image=fortio/fortio:1.76.0 \
  --overrides='{"spec":{"nodeSelector":{"lab/role":"client"}}}' -- server >/dev/null
kubectl -n ambient wait --for=condition=Ready pod/fresh --timeout=60s >/dev/null
policy ambient | kubectl apply -f - >/dev/null 2>&1
sleep 5
{
  echo "ambient, HTTP-only DENY /debug, fresh pod (sa default): /debug -> $(probe ambient /debug pod/fresh fresh), /echo -> $(probe ambient /echo pod/fresh fresh)"
  echo "istiod status on that policy:"
  kubectl -n ambient get authorizationpolicy deny-debug \
    -o jsonpath='{range .status.conditions[*]}  {.type}={.status} reason={.reason}: {.message}{"\n"}{end}'
  echo "policy as pushed to ztunnel (istioctl ztunnel-config policies):"
  istioctl ztunnel-config policies -o json | jq -c '.[] | select(.namespace=="ambient")'
} | tee -a "$OUT/authz-ztunnel-http-deny.txt"
kubectl -n ambient delete authorizationpolicy deny-debug >/dev/null

l4policy | kubectl apply -f - >/dev/null
sleep 5
echo "ambient, L4 DENY principal sa/client: sa/client -> $(probe ambient /echo), sa/default (fresh pod) -> $(probe ambient /echo pod/fresh fresh)" \
  | tee -a "$OUT/authz-ztunnel-http-deny.txt"
kubectl -n ambient delete authorizationpolicy deny-client-l4 >/dev/null
kubectl -n ambient delete pod fresh >/dev/null
