#!/usr/bin/env bash
# The lab VM has no systemd (PID 1 is tini), so nothing starts dockerd. The
# local registry is plain HTTP at kind-registry:5000 (the same name the nodes
# and the Kyverno pod use), so dockerd must treat it as insecure.
set -euo pipefail
grep -q ' kind-registry$' /etc/hosts || echo '127.0.0.1 kind-registry' | sudo tee -a /etc/hosts >/dev/null
sudo mkdir -p /etc/docker
echo '{"insecure-registries":["kind-registry:5000"]}' | sudo tee /etc/docker/daemon.json >/dev/null
if sudo docker info 2>/dev/null | grep -q 'kind-registry:5000'; then exit 0; fi
sudo pkill -x dockerd 2>/dev/null && sleep 3 || true
sudo sh -c 'nohup dockerd > /var/log/dockerd.log 2>&1 &'
for i in $(seq 1 30); do sudo docker info >/dev/null 2>&1 && break; sleep 1; done
sudo chmod 666 /var/run/docker.sock
sudo docker info | grep -A1 'Insecure Registries'
