#!/usr/bin/env bash
# cosign v3 writes a sigstore bundle as an OCI 1.1 referrer. Which Kyverno
# verifyImages settings accept it? Plus a negative control on provenance.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$LAB/results/format-compat"; mkdir -p "$OUT"
P="$LAB/manifests/policy-verify.yaml"
R=kind-registry:5000/demo/app
{
kyverno_mode default
apply_policy "$P" 2>/dev/null;                    try_pod defaults        "$R:v1"
kyverno_mode default
apply_policy "$P" cosignOCI11=true 2>/dev/null;   try_pod cosignOCI11     "$R:v1"
kyverno_mode default
apply_policy "$P" type=SigstoreBundle 2>/dev/null; try_pod sigstorebundle "$R:v1"
sed 's#value: https://netf.io/lab/builder/laptop#value: https://ci.example/builder/trusted#' "$P" > /tmp/policy-wrongbuilder.yaml
kyverno_mode default
apply_policy /tmp/policy-wrongbuilder.yaml type=SigstoreBundle 2>/dev/null; try_pod wrong-builder "$R:v1"
} | tee "$OUT/results.tsv"
apply_policy "$P" type=SigstoreBundle 2>/dev/null
