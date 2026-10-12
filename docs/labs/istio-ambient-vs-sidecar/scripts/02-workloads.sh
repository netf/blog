#!/usr/bin/env bash
# Four namespaces with identical client/server pairs:
#   baseline   no mesh
#   sidecar    istio-injection=enabled
#   ambient    ztunnel only (L4)
#   ambient-wp ztunnel + a namespace waypoint (L7)
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"

kubectl create ns baseline --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns sidecar --dry-run=client -o yaml | kubectl apply -f -
kubectl label ns sidecar istio-injection=enabled --overwrite
for ns in ambient ambient-wp; do
  kubectl create ns "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label ns "$ns" istio.io/dataplane-mode=ambient --overwrite
done

for ns in baseline sidecar ambient ambient-wp; do
  sed "s/NAMESPACE/${ns}/g" "$LAB_DIR/manifests/workload.yaml" | kubectl apply -f -
done

# Waypoint for ambient-wp only. --enroll-namespace labels the namespace with
# istio.io/use-waypoint=waypoint so all its services are routed through it.
istioctl waypoint apply -n ambient-wp --enroll-namespace --wait

for ns in baseline sidecar ambient ambient-wp; do
  kubectl -n "$ns" rollout status deploy/server deploy/client --timeout=180s
done
kubectl get pods -A -o wide -l 'app in (server,client)'
kubectl -n ambient-wp get pods -o wide
