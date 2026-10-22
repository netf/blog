#!/usr/bin/env bash
# Fail-closed vs fail-open. Registry down (cold and warm verify cache), Audit
# mode, and Kyverno itself down under webhook failurePolicy Fail vs Ignore.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$LAB/results/registry-down"; mkdir -p "$OUT"
R=kind-registry:5000/demo/app
P="$LAB/manifests/policy-verify.yaml"
# pause/unpause rather than stop/start: after a docker start, Kyverno still got
# "dial tcp" errors for the next admission, which confounded the warm-cache test.
# A paused registry keeps its address and answers nothing.
reg() { case $1 in stop) docker pause kind-registry >/dev/null ;;
                   start) docker unpause kind-registry >/dev/null; sleep 2 ;; esac; }
{
kyverno_mode default; apply_policy "$P" type=SigstoreBundle 2>/dev/null
reg stop;  try_pod regdown-cold "$R:v1"; reg start
try_pod warmup "$R:v1"
reg stop;  try_pod regdown-warm-cache "$R:v1"; reg start

sed 's/failureAction: Enforce/failureAction: Audit/' "$P" > /tmp/policy-audit.yaml
kyverno_mode default; apply_policy /tmp/policy-audit.yaml type=SigstoreBundle 2>/dev/null
reg stop;  try_pod regdown-audit "$R:v1"; reg start
try_pod unsigned-audit "$R:evil"

for fp in Fail Ignore; do
  sed "s/failurePolicy: Fail/failurePolicy: $fp/" "$P" > /tmp/policy-fp.yaml
  kyverno_mode default; apply_policy /tmp/policy-fp.yaml type=SigstoreBundle 2>/dev/null
  kubectl -n kyverno scale deploy/kyverno-admission-controller --replicas=0 >/dev/null
  kubectl -n kyverno wait --for=delete pod -l app.kubernetes.io/component=admission-controller --timeout=120s >/dev/null 2>&1
  sleep 5
  try_pod "kyverno-down-$(echo $fp | tr A-Z a-z)-unsigned" "$R:evil"
  kubectl -n kyverno scale deploy/kyverno-admission-controller --replicas=1 >/dev/null
  kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s >/dev/null
done
} | tee "$OUT/results.tsv"
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -i kyverno > "$OUT/webhooks.txt"
apply_policy "$P" type=SigstoreBundle 2>/dev/null
