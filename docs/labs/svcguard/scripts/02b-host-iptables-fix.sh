#!/usr/bin/env bash
# Needed on the lab VM only: Docker programs the Kind bridge into nf_tables, but a
# legacy `filter` table with `FORWARD DROP` also exists and drops node traffic.
# Copied from the Istio lab; adds the IPv6 equivalent for dual-stack clusters.
set -euo pipefail
BR="br-$(docker network inspect kind -f '{{.Id}}' | cut -c1-12)"
V4=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -v : | head -1)
V6=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep : | head -1 || true)
for ipt in iptables-legacy ip6tables-legacy; do
  sudo $ipt -C FORWARD -i "$BR" -j ACCEPT 2>/dev/null || sudo $ipt -I FORWARD -i "$BR" -j ACCEPT
  sudo $ipt -C FORWARD -o "$BR" -j ACCEPT 2>/dev/null || sudo $ipt -I FORWARD -o "$BR" -j ACCEPT
done
sudo iptables-legacy -t nat -C POSTROUTING -s "$V4" ! -o "$BR" -j MASQUERADE 2>/dev/null ||
  sudo iptables-legacy -t nat -A POSTROUTING -s "$V4" ! -o "$BR" -j MASQUERADE
if [ -n "$V6" ]; then sudo ip6tables-legacy -t nat -C POSTROUTING -s "$V6" ! -o "$BR" -j MASQUERADE 2>/dev/null ||
  sudo ip6tables-legacy -t nat -A POSTROUTING -s "$V6" ! -o "$BR" -j MASQUERADE; fi
