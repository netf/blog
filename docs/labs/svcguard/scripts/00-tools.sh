#!/usr/bin/env bash
# Installs the exact tool versions pinned on lab day (2026-11-17) into ~/bin.
set -euo pipefail
KIND_VERSION=v0.33.0
KUBECTL_VERSION=v1.37.2
HELM_VERSION=v3.22.1
CILIUM_CLI_VERSION=v0.20.3
mkdir -p ~/bin && cd /tmp
curl -fsLo ~/bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
curl -fsLo ~/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
curl -fsL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar xz
mv linux-amd64/helm ~/bin/
curl -fsL "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" | tar xz -C ~/bin
chmod +x ~/bin/kind ~/bin/kubectl
sudo sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
