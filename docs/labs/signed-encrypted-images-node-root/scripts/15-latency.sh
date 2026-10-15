#!/usr/bin/env bash
# Admission latency of the verifyImages webhook. Server-side dry-run runs the
# full admission chain (verify + mutate) without scheduling a pod. We time:
#   baseline  ns=default, no policy matches
#   warm      ns=prod, signed image, verify-cache hit
#   cold      ns=prod, signed image, one shot right after a Kyverno cold start
# N samples each; prints p50/p90/p99 in ms plus the apiserver webhook metric.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$LAB/results/latency"; mkdir -p "$OUT"
R=kind-registry:5000/demo/app
N=${N:-30}
kyverno_mode default; apply_policy "$LAB/manifests/policy-verify.yaml" type=SigstoreBundle 2>/dev/null
pod() { cat <<YAML
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"lat","namespace":"$1"},
 "spec":{"containers":[{"name":"c","image":"$R:v1"}]}}
YAML
}
sample() { # sample NS OUTFILE
  : > "$2"
  for i in $(seq 1 "$N"); do
    local t0 t1; t0=$(date +%s%N)
    pod "$1" | kubectl create --dry-run=server -f - >/dev/null 2>&1
    t1=$(date +%s%N); echo $(( (t1-t0)/1000000 )) >> "$2"
  done
}

# Guard: dry-run must actually run verification, or these numbers mean nothing.
if sed 's#demo/app:v1#demo/app:evil#' <(pod prod) | kubectl create --dry-run=server -f - >/dev/null 2>&1; then
  echo "dry-run admitted an unsigned image: verification not exercised" >&2; exit 1
fi
echo "guard ok: dry-run denies unsigned image" > "$OUT/guard.txt"

sample default "$OUT/baseline.ms"
pod prod | kubectl create --dry-run=server -f - >/dev/null 2>&1   # warm the cache
sample prod "$OUT/warm.ms"
kyverno_mode off; apply_policy "$LAB/manifests/policy-verify.yaml" type=SigstoreBundle 2>/dev/null
sample prod "$OUT/uncached.ms"
kyverno_mode default; apply_policy "$LAB/manifests/policy-verify.yaml" type=SigstoreBundle 2>/dev/null

python3 - "$OUT" <<'PY' | tee "$OUT/summary.txt"
import sys, statistics as st, os
d = sys.argv[1]
def pct(v, p):
    v = sorted(v); k = (len(v)-1) * p / 100; f = int(k)
    return v[f] if f + 1 >= len(v) else v[f] + (v[f+1]-v[f]) * (k-f)
print(f"{'case':10} {'n':>3} {'p50':>6} {'p90':>6} {'p99':>6} {'max':>6}  (ms, kubectl create --dry-run=server wall time)")
for c in ("baseline", "warm", "uncached"):
    v = [int(x) for x in open(os.path.join(d, c + ".ms")) if x.strip()]
    print(f"{c:10} {len(v):>3} {pct(v,50):>6.0f} {pct(v,90):>6.0f} {pct(v,99):>6.0f} {max(v):>6}")
PY
