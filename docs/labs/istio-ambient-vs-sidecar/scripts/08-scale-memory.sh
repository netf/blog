#!/usr/bin/env bash
# Data-plane memory as the mesh grows, two ways:
#  (a) config fan-out: add 200 Services (with endpoints) in an unrelated
#      namespace and watch per-proxy memory and Envoy cluster counts;
#  (b) pod density: scale each server Deployment to 10 replicas.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$LAB_DIR/results/scale"
mkdir -p "$OUT"

mem() { # label -> one line per data-plane container (MiB working set)
  for node in mesh-lab-worker mesh-lab-worker2; do
    docker exec "$node" crictl stats -o json | jq -r --arg node "$node" --arg l "$1" '
      .stats[] | select(.memory != null) | .attributes.labels as $lab
      | select(($lab["io.kubernetes.container.name"] == "istio-proxy"))
      | [$l, $node, $lab["io.kubernetes.pod.namespace"], $lab["io.kubernetes.pod.name"],
         ((.memory.workingSetBytes.value|tonumber)/1048576*10|floor/10)] | @tsv'
  done
}
counts() { # label
  local c
  c=$(istioctl proxy-config cluster deploy/client -n sidecar | tail -n +2 | wc -l)
  echo "$1 sidecar-client envoy clusters: $c" | tee -a "$OUT/clusters.txt"
  c=$(istioctl proxy-config cluster deploy/waypoint -n ambient-wp | tail -n +2 | wc -l)
  echo "$1 waypoint envoy clusters: $c" | tee -a "$OUT/clusters.txt"
  c=$(istioctl ztunnel-config service | tail -n +2 | wc -l)
  echo "$1 ztunnel known services: $c" | tee -a "$OUT/clusters.txt"
}

: > "$OUT/clusters.txt"; : > "$OUT/requests.txt"
# Start from fresh proxies: Envoy does not hand memory back after config shrinks,
# so a previous run would inflate the "before" numbers.
kubectl delete ns fanout --ignore-not-found --wait=true
kubectl -n sidecar rollout restart deploy/client deploy/server
kubectl -n ambient-wp rollout restart deploy/waypoint
kubectl -n istio-system rollout restart ds/ztunnel
kubectl -n sidecar rollout status deploy/client deploy/server
kubectl -n ambient-wp rollout status deploy/waypoint
kubectl -n istio-system rollout status ds/ztunnel
sleep 60
mem before > "$OUT/memory-fanout.tsv"
counts before

kubectl create ns fanout --dry-run=client -o yaml | kubectl apply -f -
kubectl -n fanout create deployment backend --image=fortio/fortio:1.76.0 --replicas=2 \
  --dry-run=client -o yaml -- fortio server | kubectl apply -f -
for i in $(seq 1 200); do
  cat <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: svc-$i
  namespace: fanout
spec:
  selector: {app: backend}
  ports:
    - {name: http, port: 8080}
    - {name: grpc, port: 8079}
EOF
done | kubectl apply -f - >/dev/null
kubectl -n fanout rollout status deploy/backend
sleep 60
mem "after-200-services" >> "$OUT/memory-fanout.tsv"
counts "after-200-services"

# Pod density, one mode at a time (both at once does not fit on one 4-CPU
# worker: see results/scale/scheduling-side-effect.txt). The fan-out Services
# are removed first so they do not inflate every new sidecar.
kubectl delete ns fanout --wait=true
sleep 30
: > "$OUT/memory-density.tsv"
for ns in sidecar ambient; do
  mem "$ns:1-replica" >> "$OUT/memory-density.tsv"
  kubectl -n "$ns" scale deploy/server --replicas=10
  kubectl -n "$ns" rollout status deploy/server --timeout=300s
  sleep 60
  mem "$ns:10-replicas" >> "$OUT/memory-density.tsv"
  # Long-running containers only: regular containers plus native sidecars
  # (init containers with restartPolicy=Always). istio-init exits after setup.
  kubectl -n "$ns" get pods -l app=server -o json | jq -r --arg ns "$ns" '
    .items[0].spec | (.containers + [(.initContainers // [])[] | select(.restartPolicy == "Always")])[]
    | "\($ns) per-pod: \(.name) requests cpu=\(.resources.requests.cpu // "-") mem=\(.resources.requests.memory // "-")"' \
    >> "$OUT/requests.txt"
  kubectl -n "$ns" scale deploy/server --replicas=1
  kubectl -n "$ns" rollout status deploy/server --timeout=120s
  sleep 20
done
kubectl -n istio-system get ds ztunnel -o jsonpath='ztunnel per-node: requests {.spec.template.spec.containers[0].resources.requests}{"\n"}' >> "$OUT/requests.txt"
cat "$OUT/requests.txt"
