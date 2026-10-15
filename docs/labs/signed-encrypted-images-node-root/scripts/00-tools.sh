#!/usr/bin/env bash
# Installs the exact tool versions used in the post. Docker comes from
# get.docker.com (its version is recorded in results/versions.txt); everything
# else is pinned below. imgcrypt has no release binaries, so ctd-decoder and
# ctr-enc are built from the tagged source with a pinned Go toolchain.
set -euo pipefail
KIND_VERSION=v0.33.0
KUBECTL_VERSION=v1.37.1
HELM_VERSION=v3.22.0
COSIGN_VERSION=v3.1.3
SYFT_VERSION=v1.54.1
GO_VERSION=1.26.9
IMGCRYPT_VERSION=v2.0.3

mkdir -p ~/bin
export PATH="$HOME/bin:/usr/local/go/bin:$PATH"

if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
fi

curl -fsSLo ~/bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
curl -fsSLo ~/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar xz -C /tmp
mv /tmp/linux-amd64/helm ~/bin/
curl -fsSLo ~/bin/cosign "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
curl -fsSL "https://github.com/anchore/syft/releases/download/${SYFT_VERSION}/syft_${SYFT_VERSION#v}_linux_amd64.tar.gz" | tar xz -C ~/bin syft
chmod +x ~/bin/kind ~/bin/kubectl ~/bin/cosign ~/bin/syft

# skopeo (encrypt/copy), gdb (gcore), jq, crane-like inspection via skopeo.
sudo apt-get update -qq
sudo apt-get install -y -qq skopeo gdb jq >/dev/null

if [ ! -x /usr/local/go/bin/go ] || ! /usr/local/go/bin/go version | grep -q "go${GO_VERSION} "; then
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | sudo tar xz -C /usr/local
fi

rm -rf /tmp/imgcrypt
git clone -q --depth 1 --branch "$IMGCRYPT_VERSION" https://github.com/containerd/imgcrypt /tmp/imgcrypt
( cd /tmp/imgcrypt/cmd && CGO_ENABLED=0 go build -o ~/bin/ctd-decoder ./ctd-decoder \
    && CGO_ENABLED=0 go build -o ~/bin/ctr-enc ./ctr )

sudo sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
