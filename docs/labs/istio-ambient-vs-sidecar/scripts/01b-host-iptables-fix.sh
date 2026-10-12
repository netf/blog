#!/usr/bin/env bash
# Only needed on hosts where BOTH iptables backends are active (seen on the
# Ubuntu 24.04 lab VM after installing Docker with get.docker.com): Docker
# programs the Kind bridge rules into nf_tables, but a legacy `filter` table with
# `FORWARD DROP` still exists and drops node-to-node and node-to-internet
# traffic. Symptom: `kubectl logs` times out dialing the kubelet on :10250 and
# istiod never becomes Ready. Skip this on a normal workstation.
set -euo pipefail
BR="br-$(docker network inspect kind -f '{{.Id}}' | cut -c1-12)"
sudo iptables-legacy -C FORWARD -i "$BR" -j ACCEPT 2>/dev/null || sudo iptables-legacy -I FORWARD -i "$BR" -j ACCEPT
sudo iptables-legacy -C FORWARD -o "$BR" -j ACCEPT 2>/dev/null || sudo iptables-legacy -I FORWARD -o "$BR" -j ACCEPT
sudo iptables-legacy -t nat -C POSTROUTING -s 172.18.0.0/16 ! -o "$BR" -j MASQUERADE 2>/dev/null ||
  sudo iptables-legacy -t nat -A POSTROUTING -s 172.18.0.0/16 ! -o "$BR" -j MASQUERADE
