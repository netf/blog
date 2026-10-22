#!/usr/bin/env bash
# Encrypted image on the keyed vs keyless node, with layer state controlled:
# plain and encrypted images share diff_ids, so a node that already unpacked
# the plain layers never needs to decrypt. Then cold pull+start timing.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$LAB/results/run-encrypted"; mkdir -p "$OUT"
R=kind-registry:5000/demo
SNAP=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots
kubectl create ns enc >/dev/null 2>&1
clean_node() { # remove every demo image on node $1; print model.bin copies left on disk
  kubectl -n enc delete pod --all --wait=true >/dev/null 2>&1
  kubectl -n prod delete pod --all --wait=true >/dev/null 2>&1
  docker exec "$1" sh -c "crictl images | awk '/demo\\//{print \$3}' | sort -u | xargs -r crictl rmi >/dev/null 2>&1; sleep 2; ls $SNAP/*/fs/opt/model/model.bin 2>/dev/null | wc -l"
}
runpod() { # runpod NAME NODE IMAGE
  kubectl -n enc run "$1" --image="$3" --restart=Never --env=APP_SECRET=lab-secret-value \
    --overrides="{\"spec\":{\"nodeName\":\"$2\"}}" >/dev/null
}
outcome() { # outcome POD: wait up to 45s, print phase/state and the last event message
  for i in $(seq 1 45); do
    ph=$(kubectl -n enc get pod "$1" -o jsonpath='{.status.phase}/{.status.containerStatuses[0].state.waiting.reason}{.status.containerStatuses[0].state.running.startedAt}')
    case $ph in Running/*|*/ErrImagePull|*/ImagePullBackOff) break ;; esac; sleep 1
  done
  uid=$(kubectl -n enc get pod "$1" -o jsonpath='{.metadata.uid}')
  msg=$(kubectl -n enc get events --field-selector involvedObject.uid=$uid -o jsonpath='{range .items[*]}{.reason}: {.message}{"\n"}{end}' | grep -E 'Failed|Pulled' | head -1 | cut -c1-400)
  printf '%s\t%s\t%s\n' "$1" "$ph" "$msg"
}
{
echo -e "#\tworker2 model.bin copies on disk after clean\t$(clean_node supply-worker2)"
runpod keyless-clean supply-worker2 "$R/app-enc:v1"; outcome keyless-clean
kubectl -n enc delete pod keyless-clean --wait=true >/dev/null 2>&1
runpod plain-first supply-worker2 "$R/app-plain:v1"; outcome plain-first
runpod keyless-after-plain supply-worker2 "$R/app-enc:v1"; outcome keyless-after-plain
echo -e "#\tworker model.bin copies on disk after clean\t$(clean_node supply-worker)"
runpod keyed-clean supply-worker "$R/app-enc:v1"; outcome keyed-clean
} | tee "$OUT/placement.tsv"

# Cold pull+start on the keyed node; the node is wiped of every demo image
# before each sample so encrypted pulls really fetch and decrypt.
N=${N:-10}
echo -e "image\trun\tleft_on_disk\tpull\tready_ms" > "$OUT/timing.tsv"
for i in $(seq 1 "$N"); do
  for img in app-plain app-enc; do
    p="t-$img"; left=$(clean_node supply-worker)
    t0=$(now_ms); runpod "$p" supply-worker "$R/$img:v1"
    kubectl -n enc wait --for=condition=Ready "pod/$p" --timeout=120s >/dev/null
    t1=$(now_ms)
    uid=$(kubectl -n enc get pod "$p" -o jsonpath='{.metadata.uid}')
    pull=$(kubectl -n enc get events --field-selector involvedObject.uid=$uid,reason=Pulled \
      -o jsonpath='{.items[0].message}' | grep -o 'in [0-9.]*m\?s' | head -1)
    echo -e "$img\t$i\t$left\t$pull\t$((t1-t0))" | tee -a "$OUT/timing.tsv"
  done
done
