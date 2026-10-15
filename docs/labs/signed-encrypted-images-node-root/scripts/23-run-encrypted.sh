#!/usr/bin/env bash
# Encrypted image on the keyed node vs the keyless node, then cold pull+start
# timing (plain vs encrypted) on the keyed node.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$LAB/results/run-encrypted"; mkdir -p "$OUT"
R=kind-registry:5000/demo
kubectl create ns enc >/dev/null 2>&1
runpod() { # runpod NAME NODE IMAGE
  kubectl -n enc delete pod "$1" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl -n enc run "$1" --image="$3" --restart=Never --env=APP_SECRET=lab-secret-value \
    --overrides="{\"spec\":{\"nodeName\":\"$2\"}}" >/dev/null
}
state() { kubectl -n enc get pod "$1" -o jsonpath='{.status.phase} {.status.containerStatuses[0].state}'; echo; }

runpod enc-keyed   supply-worker  "$R/app-enc:v1"
runpod enc-keyless supply-worker2 "$R/app-enc:v1"
runpod plain-keyless supply-worker2 "$R/app-plain:v1"
sleep 30
{
for p in enc-keyed enc-keyless plain-keyless; do echo "== $p: $(state $p)"; done
echo "== events for enc-keyless"
kubectl -n enc get events --field-selector involvedObject.name=enc-keyless \
  -o custom-columns=REASON:.reason,MSG:.message --no-headers | sort -u | cut -c1-400
} | tee "$OUT/placement.txt"

# Cold pull+start on the keyed node. Image removed from the node before each run.
# pull = kubelet's "Successfully pulled image ... in X" event; ready = wall time
# from create until the pod is Ready.
N=${N:-10}
echo -e "image\trun\tpull\tready_ms" > "$OUT/timing.tsv"
for i in $(seq 1 "$N"); do
  for img in app-plain app-enc; do
    p="t-$img"
    kubectl -n enc delete pod "$p" --ignore-not-found --wait=true >/dev/null 2>&1
    docker exec supply-worker crictl rmi "$R/$img:v1" >/dev/null 2>&1
    t0=$(now_ms); runpod "$p" supply-worker "$R/$img:v1"
    kubectl -n enc wait --for=condition=Ready "pod/$p" --timeout=120s >/dev/null
    t1=$(now_ms)
    uid=$(kubectl -n enc get pod "$p" -o jsonpath='{.metadata.uid}')
    pull=$(kubectl -n enc get events --field-selector involvedObject.uid=$uid,reason=Pulled \
      -o jsonpath='{.items[-1:].message}' | grep -o 'in [0-9.]*m\?s' | head -1)
    echo -e "$img\t$i\t$pull\t$((t1-t0))" | tee -a "$OUT/timing.tsv"
  done
done
