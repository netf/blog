#!/usr/bin/env bash
# Does a second admission-controller replica keep enforcement through a graceful
# shutdown of one replica?
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$LAB/results/failure-modes"; mkdir -p "$OUT"
hooks() { kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations -o name | grep -c kyverno-resource; }
helm upgrade kyverno kyverno/kyverno --version 3.9.1 -n kyverno --set features.registryClient.allowInsecure=true \
  --set admissionController.replicas=2 --wait --timeout 5m >/dev/null
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s >/dev/null; sleep 10
apply_policy "$LAB/manifests/policy-verify.yaml" type=SigstoreBundle 2>/dev/null
POD=$(kubectl -n kyverno get pod -l app.kubernetes.io/component=admission-controller -o jsonpath='{.items[0].metadata.name}')
{
echo -e "#\treplicas\t$(kubectl -n kyverno get deploy kyverno-admission-controller -o jsonpath='{.status.readyReplicas}')"
echo -e "#\tresource-webhooks-before\t$(hooks)"
kubectl -n kyverno delete pod "$POD" --wait=false >/dev/null
for t in 1 2 5 10; do sleep $t; echo -e "#\tresource-webhooks-after-${t}s-more\t$(hooks)"; try_pod "two-rep-unsigned-$t" kind-registry:5000/demo/app:evil; done
} | tee "$OUT/two-replicas.tsv"
