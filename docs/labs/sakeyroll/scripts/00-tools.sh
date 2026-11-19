#!/usr/bin/env bash
# Installs the tool versions pinned on lab day (2026-11-19) into ~/bin and /usr/local/go.
set -euo pipefail
KIND_VERSION=v0.33.0
KUBECTL_VERSION=v1.37.2
HELM_VERSION=v3.22.1
OPENBAO_VERSION=2.7.2
GO_VERSION=1.27.4
mkdir -p ~/bin && cd /tmp
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sudo sh
sudo apt-get update -qq && sudo apt-get install -y -qq softhsm2 opensc nftables iptables iproute2 >/dev/null
curl -fsLo ~/bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
curl -fsLo ~/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
curl -fsL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar xz && mv linux-amd64/helm ~/bin/
curl -fsL "https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/openbao_${OPENBAO_VERSION}_linux_amd64.tar.gz" | tar xz -C ~/bin bao
curl -fsLo /tmp/go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf /tmp/go.tar.gz
chmod +x ~/bin/kind ~/bin/kubectl
sudo sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
