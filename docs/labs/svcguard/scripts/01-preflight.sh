#!/usr/bin/env bash
# Prints the environment facts recorded in environment.md. Read-only except the
# throwaway netns / nft table / tc qdisc probes, which are removed again.
set -uo pipefail
export PATH=~/bin:$PATH
s(){ echo; echo "### $*"; }
s nproc; nproc
s free; free -h
s balloon; grep balloon /proc/vmstat; ps -eo rss= | awk '{t+=$1} END {print "sum RSS MiB", t/1024}'
s df; df -h / /var/lib/docker
s virt; systemd-detect-virt 2>&1; cat /proc/cmdline; ps -p 1 -o comm=
s os; . /etc/os-release; echo "$PRETTY_NAME"; uname -r
s cgroup; stat -fc %T /sys/fs/cgroup; cat /sys/fs/cgroup/cgroup.controllers
s iptables; iptables -V; iptables-legacy -V 2>/dev/null; sudo iptables-legacy -S FORWARD 2>/dev/null | head -3; nft --version
s nft-usable; sudo nft add table inet preflight && sudo nft add chain inet preflight c '{ type filter hook input priority 0; policy accept; }' && sudo nft list table inet preflight && sudo nft delete table inet preflight && echo NFT_OK
s modules; ls /lib/modules 2>&1 | head -2; wc -l < /proc/modules
for m in br_netfilter overlay nf_conntrack ip_vs nf_tables xt_socket; do printf '%s: ' $m; if [ -d /sys/module/$m ]; then echo present; else zcat /proc/config.gz 2>/dev/null | grep -i "CONFIG_$(echo $m | tr a-z A-Z)=" || echo "no /sys/module entry"; fi; done
s kconfig; ls /proc/config.gz /boot/config-$(uname -r) 2>&1
s sysctl; sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.ipv6.conf.all.disable_ipv6 2>&1
s btf; ls -la /sys/kernel/btf/vmlinux
s bpf; cat /proc/sys/kernel/unprivileged_bpf_disabled; sudo bpftool version 2>&1 | head -1; mount | grep -E "bpf|tracefs" ; cat /sys/kernel/security/lsm 2>/dev/null
s netns-tc; sudo ip netns del pf 2>/dev/null; sudo ip netns add pf && sudo ip -n pf link set lo up && sudo tc -n pf qdisc add dev lo clsact && sudo tc -n pf qdisc show dev lo && sudo ip netns del pf && echo NETNS_TC_OK
s docker; docker version --format 'server {{.Server.Version}} client {{.Client.Version}}'; docker info 2>/dev/null | grep -iE "storage driver|cgroup|rootless|security|root dir|firewall|kernel"
s tools; kind version; kubectl version --client 2>&1 | head -1; helm version --short; cilium version --client 2>&1 | head -1; python3 --version; jq --version
s egress; for u in https://registry-1.docker.io/v2/ https://ghcr.io/v2/ https://quay.io/v2/ https://registry.k8s.io/v2/ https://helm.cilium.io/index.yaml https://charts.jetstack.io/index.yaml https://traefik.github.io/charts/index.yaml https://metallb.github.io/metallb/index.yaml https://strimzi.io/charts/index.yaml https://dl.k8s.io/release/stable.txt; do printf '%s ' "$u"; curl -s -o /dev/null -m 15 -w '%{http_code}\n' "$u"; done
s limits; ulimit -n; ulimit -u
s clock; date -u; (chronyc tracking 2>&1 || timedatectl 2>&1) | head -3; python3 - <<'P'
import socket,struct,time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(5)
s.sendto(b'\x1b'+47*b'\0',('time.google.com',123));d=s.recv(48)
t=struct.unpack('!12I',d)[10]-2208988800;print('ntp offset s (1s resolution):',t-int(time.time()))
P
