#!/usr/bin/env bash
# Installs the exact tool versions used in the post into ~/bin and unpacks both
# Istio release tarballs into /tmp (the 1.31.x Helm charts were not published to
# the public Helm repo or the OCI registry when this lab was run, so the charts
# shipped inside the release tarballs are used for both versions).
set -euo pipefail
KIND_VERSION=v0.33.0
KUBECTL_VERSION=v1.37.1
HELM_VERSION=v3.22.0
ISTIO_OLD=1.30.5
ISTIO_NEW=1.31.1

mkdir -p ~/bin
cd /tmp
curl -sLo ~/bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
curl -sLo ~/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
curl -sL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar xz
mv linux-amd64/helm ~/bin/
chmod +x ~/bin/kind ~/bin/kubectl
for v in "$ISTIO_OLD" "$ISTIO_NEW"; do
  curl -sL "https://github.com/istio/istio/releases/download/${v}/istio-${v}-linux-amd64.tar.gz" | tar xz
done
cp "/tmp/istio-${ISTIO_NEW}/bin/istioctl" ~/bin/istioctl

# Kind with three nodes needs more inotify instances than the Ubuntu default.
sudo sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
