#!/usr/bin/env bash
# Create the network jail: a veth pair linking the host (root) netns to NETNS.
#   open      - accept all egress
#   allowlist - drop all egress except TCP to the registry (the hardened arm)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
MODE="${1:-allowlist}"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

ip netns del "${NETNS}" 2>/dev/null || true
ip link del "${VETH_HOST}" 2>/dev/null || true
ip netns add "${NETNS}"
ip link add "${VETH_HOST}" type veth peer name "${VETH_NS}"
ip link set "${VETH_NS}" netns "${NETNS}"
ip addr add "${HOST_IP}/24" dev "${VETH_HOST}"
ip link set "${VETH_HOST}" up
ip -n "${NETNS}" addr add "${NS_IP}/24" dev "${VETH_NS}"
ip -n "${NETNS}" link set "${VETH_NS}" up
ip -n "${NETNS}" link set lo up
ip -n "${NETNS}" route add default via "${HOST_IP}"

ip netns exec "${NETNS}" nft flush ruleset
if [ "${MODE}" = allowlist ]; then
  ip netns exec "${NETNS}" nft -f - <<NFT
table inet egress {
  chain output {
    type filter hook output priority 0; policy drop;
    oif "lo" accept
    ct state established,related accept
    ip daddr ${HOST_IP} tcp dport ${REGISTRY_PORT} accept
  }
}
NFT
else
  ip netns exec "${NETNS}" nft -f - <<NFT
table inet egress {
  chain output {
    type filter hook output priority 0; policy accept;
  }
}
NFT
fi
ip netns exec "${NETNS}" nft list ruleset > "${RESULTS}/netns-${MODE}.nft"
log "netns ${NETNS}: ${MODE} egress"
