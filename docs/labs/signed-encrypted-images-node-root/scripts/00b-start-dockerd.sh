#!/usr/bin/env bash
# The lab VM has no systemd (PID 1 is tini), so nothing starts dockerd.
set -euo pipefail
sudo docker info >/dev/null 2>&1 && exit 0
sudo sh -c 'nohup dockerd > /var/log/dockerd.log 2>&1 &'
for i in $(seq 1 30); do sudo docker info >/dev/null 2>&1 && exit 0; sleep 1; done
echo "dockerd did not start" >&2; exit 1
