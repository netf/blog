#!/usr/bin/env bash
# The Kind nodes in the lab VM had no direct egress, so every image is pulled on
# the host and side-loaded. `kind load docker-image` fails on multi-arch images
# with Docker's containerd image store ("content digest ... not found"), so the
# images are saved as single-platform archives first.
set -euo pipefail
IMAGES=(fortio/fortio:1.76.0)
for v in 1.30.5 1.31.1; do
  for i in pilot proxyv2 install-cni ztunnel; do
    IMAGES+=("docker.io/istio/${i}:${v}-distroless")
  done
done
for img in "${IMAGES[@]}"; do
  docker pull -q "$img"
  f="/tmp/img-$(echo "$img" | tr '/:' '__').tar"
  docker save --platform linux/amd64 -o "$f" "$img"
  kind load image-archive --name mesh-lab "$f"
done
