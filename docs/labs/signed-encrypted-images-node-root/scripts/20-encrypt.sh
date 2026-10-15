#!/usr/bin/env bash
# Encrypts app:v1's layers with ocicrypt (JWE, RSA-4096) via skopeo, and makes a
# plain single-arch copy of the same platform image as the fair baseline.
# The private key is the "node-side key" Part 2 installs on one node only.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$LAB/results/encrypt"; mkdir -p "$OUT" "$LAB/keys"
R=kind-registry:5000/demo
K="$LAB/keys"
[ -f "$K/enc-priv.pem" ] || openssl genrsa -out "$K/enc-priv.pem" 4096 2>/dev/null
openssl rsa -in "$K/enc-priv.pem" -pubout -out "$K/enc-pub.pem" 2>/dev/null
SRC="docker://$(cat "$LAB/results/sign/signed-ref.txt")"
TLS=(--src-tls-verify=false --dest-tls-verify=false)
skopeo copy -q "${TLS[@]}" "$SRC" "docker://$R/app-plain:v1"
skopeo copy -q "${TLS[@]}" --encryption-key "jwe:$K/enc-pub.pem" "$SRC" "docker://$R/app-enc:v1"
for img in app-plain app-enc; do
  echo "== $img"; skopeo inspect --tls-verify=false "docker://$R/$img:v1" | jq -r '.Digest, (.LayersData[] | "\(.MIMEType) \(.Size)")'
done | tee "$OUT/layers.txt"
