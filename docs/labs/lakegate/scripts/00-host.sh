#!/usr/bin/env bash
# Lab VM only. No systemd (PID 1 is tini), so dockerd is started by hand; and a legacy
# iptables `filter` table with `FORWARD DROP` exists next to Docker's nf_tables rules. With
# br_netfilter on, bridged container-to-container packets traverse that chain and are dropped
# (Lakekeeper could not reach its Postgres on the same Compose network).
set -euo pipefail
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sudo sh
sudo apt-get install -y iptables nftables iproute2 jq python3-venv >/dev/null
if ! sudo docker info >/dev/null 2>&1; then
  sudo sh -c 'nohup dockerd > /var/log/dockerd.log 2>&1 &'
  for i in $(seq 1 30); do sudo docker info >/dev/null 2>&1 && break; sleep 1; done
fi
sudo docker info >/dev/null 2>&1 || { echo "dockerd did not start; see /var/log/dockerd.log" >&2; exit 1; }
sudo chmod 666 /var/run/docker.sock
for ifc in 'br-+' docker0; do
  sudo iptables-legacy -C FORWARD -i "$ifc" -j ACCEPT 2>/dev/null || sudo iptables-legacy -I FORWARD -i "$ifc" -j ACCEPT
  sudo iptables-legacy -C FORWARD -o "$ifc" -j ACCEPT 2>/dev/null || sudo iptables-legacy -I FORWARD -o "$ifc" -j ACCEPT
done
