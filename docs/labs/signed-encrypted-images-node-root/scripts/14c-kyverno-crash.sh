#!/usr/bin/env bash
# Contrast with a graceful scale-down: SIGKILL the admission controller, so it
# can't clean up its webhooks, and admit an unsigned image while it restarts.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$LAB/results/failure-modes"; mkdir -p "$OUT"
hooks() { kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations -o name | grep -c kyverno-resource; }
POD=$(kubectl -n kyverno get pod -l app.kubernetes.io/component=admission-controller -o jsonpath='{.items[0].metadata.name}')
CID=$(kubectl -n kyverno get pod "$POD" -o jsonpath='{.status.containerStatuses[0].containerID}' | cut -d/ -f3)
NODE=$(kubectl -n kyverno get pod "$POD" -o jsonpath='{.spec.nodeName}')
HPID=$(docker exec "$NODE" crictl inspect --output go-template --template '{{.info.pid}}' "$CID")
{
echo -e "#\tresource-webhooks-before-kill\t$(hooks)"
docker exec "$NODE" kill -9 "$HPID"
echo -e "#\tresource-webhooks-right-after-kill\t$(hooks)"
try_pod crash-unsigned kind-registry:5000/demo/app:evil
echo -e "#\tresource-webhooks-after-try\t$(hooks)"
} | tee "$OUT/kyverno-crash.tsv"
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s >/dev/null
kubectl -n kyverno get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}' > "$OUT/kyverno-crash-restarts.txt"
