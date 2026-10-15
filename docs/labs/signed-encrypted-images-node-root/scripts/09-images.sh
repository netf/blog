#!/usr/bin/env bash
# Builds and pushes app:v1 (to be signed) and app:evil (never signed; returns
# "EVIL" from /whoami). Docker 29 pushes each as an OCI index with a BuildKit
# attestation manifest; the index digest is what gets signed.
set -euo pipefail
APP="$(cd "$(dirname "$0")/../app" && pwd)"; cd "$APP"
R=kind-registry:5000/demo/app
bash build.sh && docker build -q -t $R:v1 . && docker push -q $R:v1
cp main.go /tmp/main.go.orig
sed -i 's/secret-len=%d/EVIL secret-len=%d/' main.go
bash build.sh && docker build -q -t $R:evil . && docker push -q $R:evil
sed -i 's/EVIL secret-len/EVIL2 secret-len/' main.go
bash build.sh && docker build -q -t $R:evil2 . && docker push -q $R:evil2
cp /tmp/main.go.orig main.go && bash build.sh
