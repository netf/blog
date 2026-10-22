#!/usr/bin/env bash
# Follow-ups to 14: (a) what happens to Kyverno's webhooks when its admission
# controller is gone, (b) warm cache + hung registry by digest, (c) Audit with
# the live policy recorded.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$LAB/results/failure-modes"; mkdir -p "$OUT"
R=kind-registry:5000/demo/app
P="$LAB/manifests/policy-verify.yaml"
GOOD=$(cut -d@ -f2 "$LAB/results/sign/signed-ref.txt")
hooks() { kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations -o name | grep -c kyverno-resource; }
kyverno_mode default; apply_policy "$P" type=SigstoreBundle 2>/dev/null
{
echo -e "#\tresource-webhooks-before-scale-down\t$(hooks)"
kubectl -n kyverno scale deploy/kyverno-admission-controller --replicas=0 >/dev/null
for t in 2 5 10 20; do sleep $t; echo -e "#\tresource-webhooks-after-${t}s-more\t$(hooks)"; done
try_pod kyverno-down-unsigned "$R:evil"
kubectl -n kyverno scale deploy/kyverno-admission-controller --replicas=1 >/dev/null
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s >/dev/null
for t in 0 5 10 20; do sleep $t; echo -e "#\tresource-webhooks-after-start+${t}s\t$(hooks)"; done
} | tee "$OUT/kyverno-down.tsv"

reg() { case $1 in stop) docker pause kind-registry >/dev/null ;;
                   start) docker unpause kind-registry >/dev/null; sleep 2 ;; esac; }
kyverno_mode default; apply_policy "$P" type=SigstoreBundle 2>/dev/null
{
try_pod warm-digest "$R@$GOOD"
reg stop; try_pod regdown-warm-digest "$R@$GOOD"; reg start
} | tee "$OUT/regdown-digest.tsv"

sed 's/failureAction: Enforce/failureAction: Audit/' "$P" > /tmp/policy-audit.yaml
kyverno_mode default; apply_policy /tmp/policy-audit.yaml type=SigstoreBundle 2>/dev/null
kubectl get clusterpolicy verify-lab-images -o jsonpath='{.spec.rules[0].verifyImages[0].failureAction}{"\n"}' > "$OUT/audit-live-failureAction.txt"
try_pod unsigned-audit "$R:evil" | tee "$OUT/audit.tsv"
kubectl get policyreports -n prod -o wide > "$OUT/audit-policyreports.txt" 2>&1
apply_policy "$P" type=SigstoreBundle 2>/dev/null
