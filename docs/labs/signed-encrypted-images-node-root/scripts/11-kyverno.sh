#!/usr/bin/env bash
# Kyverno v1.19.1 (chart 3.9.1). allowInsecure is needed only because the lab
# registry is plain HTTP; the admission controller still verifies signatures.
set -euo pipefail
export PATH="$HOME/bin:$PATH"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null
helm upgrade --install kyverno kyverno/kyverno --version 3.9.1 -n kyverno --create-namespace \
  --set features.registryClient.allowInsecure=true \
  --wait --timeout 6m
kubectl -n kyverno get pods -o wide
kubectl -n kyverno get deploy -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
kubectl create ns prod --dry-run=client -o yaml | kubectl apply -f - >/dev/null
