#!/usr/bin/env bash
# The lab VM has no systemd (PID 1 is tini), so nothing starts dockerd.
# IPv6 is enabled so Kind can create dual-stack clusters.
set -euo pipefail
sudo mkdir -p /etc/docker
echo '{"ipv6":true,"ip6tables":true,"fixed-cidr-v6":"fd00:d0c::/64"}' | sudo tee /etc/docker/daemon.json >/dev/null
if sudo docker info >/dev/null 2>&1; then
  # daemon.json only applies on start; refuse to report success for a daemon started without it.
  sudo docker network inspect bridge -f '{{.EnableIPv6}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' |
    grep -q '^true .*fd00:d0c::/64' ||
    { echo "dockerd is running without the IPv6 settings in /etc/docker/daemon.json; restart it" >&2; exit 1; }
  sudo chmod 666 /var/run/docker.sock; exit 0
fi
sudo sh -c 'nohup dockerd > /var/log/dockerd.log 2>&1 &'
for i in $(seq 1 30); do sudo docker info >/dev/null 2>&1 && break; sleep 1; done
sudo docker info >/dev/null 2>&1 || { echo "dockerd did not start; see /var/log/dockerd.log" >&2; exit 1; }
sudo chmod 666 /var/run/docker.sock
