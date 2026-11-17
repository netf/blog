# Environment preflight: svcguard

Recorded 2026-11-17 before the first measurement. `scripts/01-preflight.sh` prints the raw facts
(`results/preflight/preflight.txt`); `results/preflight/kconfig.txt` holds the kernel config lines
that matter; `results/preflight/sources.md` records what each cited source says today.

## Compute

| What | Value | How checked |
|---|---|---|
| CPU | 4 vCPU | `nproc` |
| Memory | 15 GiB; `free` shows ~5 GiB available because a 10 GiB hypervisor balloon (`balloon_inflate` 2,621,440 pages) is counted as used. Process RSS at start: 0.9 GiB. | `free -h`, `/proc/vmstat`, `ps -eo rss=` |
| Disk | 254 GB, 246 GB free; `/var/lib/docker` on the same disk | `df -h` |
| Virtualisation | `kvm` (Firecracker-style microVM; `reboot=k panic=1 nomodule` on the cmdline). PID 1 is `tini`, not systemd. Not a container, no nested virt used. | `systemd-detect-virt`, `/proc/cmdline` |
| OS / kernel | Ubuntu 24.04.5, Linux 6.12.113+ | `/etc/os-release`, `uname -r` |
| Limits / clock | `ulimit -n` 524288; no NTP daemon, SNTP offset 0 s at 1 s resolution. All latency numbers are measured inside one process, so cross-process clock skew does not enter any result. | `ulimit`, SNTP query to time.google.com |

**Cluster sizing decision:** each lab cluster is 1 control plane + 1 worker. With 4 vCPU the
three dataplane clusters run **sequentially**, one at a time, never side by side, so one cluster's
load can't leak into another's latency numbers.

## Kernel

| What | Value |
|---|---|
| cgroups | v2 (`cgroup2fs`), controllers `cpuset cpu io memory hugetlb pids` |
| Modules | Monolithic kernel: no `/lib/modules`, `/proc/modules` empty. Everything below is built in or absent. |
| `br_netfilter` | built in (`CONFIG_BRIDGE_NETFILTER=y`, `net.bridge.bridge-nf-call-iptables = 1`) |
| `overlay`, `nf_conntrack`, `nf_tables` (+ `nft_nat`, `nft_ct`, `nft_fib_inet`, `nft_numgen`) | built in |
| iptables | 1.8.10, `nf_tables` backend; a legacy `filter` table with `FORWARD DROP` also exists (dual backend) |
| nftables usable | yes: created a table with a hook chain and deleted it (`nft` 1.0.9) |
| `ip_vs`, `ip_set` | **not built** (`# CONFIG_IP_VS is not set`, `# CONFIG_IP_SET is not set`). No arm uses IPVS. |
| VXLAN / GENEVE | **not built** (`# CONFIG_VXLAN is not set`, `# CONFIG_GENEVE is not set`) |
| iptables `CT` target, `xt_socket`, `TPROXY` | **not built** |
| BTF | `/sys/kernel/btf/vmlinux` present (5.5 MB) |
| eBPF | `CONFIG_BPF_SYSCALL=y`, `CONFIG_BPF_JIT=y`, `CONFIG_CGROUP_BPF=y`, `CONFIG_NET_CLS_BPF=y`, `CONFIG_NET_CLS_ACT=y`; bpffs mounted; `unprivileged_bpf_disabled=2` (root-only, which is what Cilium runs as); LSMs `capability,landlock,selinux,bpf` |
| netns / tc | `ip netns add`, `tc qdisc add ... clsact` inside it: OK (with sudo). `netem` is not built; nothing here needs it. |

## Container tooling

| Tool | Version | Notes |
|---|---|---|
| Docker | 29.10.0 (client and server) | installed with `get.docker.com` (not pinned); rootful; overlayfs storage driver; cgroupfs driver, cgroup v2; iptables firewall backend. Started by hand (`scripts/00b-start-dockerd.sh`) because there is no systemd. IPv6 enabled for dual-stack Kind. |
| Kind | v0.33.0 | throwaway `kind create cluster` + delete OK (26 s to Ready) |
| Node image | `kindest/node:v1.37.2`, **built locally** with `kind build node-image --type release v1.37.2` from the official release tarballs (image ID `sha256:b98ddac42a08…`). Kind v0.33.0 only publishes up to v1.37.0. Debian 13, containerd 2.3.4. |
| kubectl | v1.37.2 | |
| Helm | v3.22.1 | |
| cilium CLI | v0.20.3 | |
| Python | 3.12.3 (host); lab image uses `python:3.13-slim` | |
| jq, nftables, iptables, iproute2 | 1.7 / 1.0.9 / 1.8.10 / 6.1.0 | `apt-get install` |

## Network

Docker Hub, ghcr.io, quay.io, registry.k8s.io, dl.k8s.io and every Helm repo the lab uses answered
(registries 401 = reachable, auth challenge). Pods on the kube-proxy clusters can reach the
internet after the iptables fix below.

## Pins on lab day (all pitch pins exist as real releases)

| Component | Pitch pin | Used | Latest on 2026-11-17 |
|---|---|---|---|
| Kubernetes | v1.37.2 | v1.37.2 | v1.37.2 |
| Kind | v0.33.0 | v0.33.0 | v0.33.0 |
| Cilium | v1.20.4 | v1.20.4 (chart and images, digests in `results/versions.txt`) | v1.20.4 |
| Envoy Gateway | latest | v1.10.0 | v1.10.0 |
| Traefik | latest | v3.7.19 (chart version recorded in `results/versions.txt`) | v3.7.19 |
| MetalLB | (not pinned) | recorded in `results/versions.txt` | |

## Deviations and workarounds (read these before the numbers)

1. **Cilium runs in native routing, not its default VXLAN tunnel.** The kernel has no VXLAN or
   GENEVE. All Kind nodes sit on one Docker bridge, so `routingMode: native` with
   `autoDirectNodeRoutes: true` is a supported, common Cilium setup. The thing under test,
   Cilium's eBPF service load balancer (ClusterIP, externalIPs, LoadBalancer, socket LB), is the
   same code in both routing modes. `cilium-dbg status` confirms `KubeProxyReplacement: True`,
   `Socket LB: Enabled`, `externalIPs: Enabled`, `LoadBalancer: Enabled`, `Host: BPF`.
2. **Cilium's L7 proxy is disabled (`l7Proxy: false`, no cilium-envoy).** The kernel lacks the
   iptables `CT` target, so Cilium logs `cannot install static proxy rules ... Extension CT
   revision 0 not supported` every ~10 s. That error persists with the L7 proxy off (Cilium 1.20
   installs the rule regardless; there is no `installIptablesRules` switch in the 1.20 chart). It
   only affects Cilium's own L7 policy / proxy redirection, which this lab does not use; ingress is
   Envoy Gateway and Traefik. Service routing through eBPF was checked directly (ClusterIP
   request answered by the right pod).
3. **Cilium also reports `Forcefully terminating sockets connected to deleted service backends
   not supported`** (`CONFIG_INET_UDP_DIAG` missing). That is UDP socket cleanup; every attack
   here is TCP.
4. **On the Cilium cluster, pods cannot resolve internet names.** Kind's node DNS shim is an
   iptables DNAT inside the node, which Cilium's eBPF host routing bypasses. Nothing in the lab
   needs pod-side internet DNS: images are pulled by containerd on the node and victims use fixed
   host aliases.
5. **Dual iptables backend on the host:** `scripts/02b-host-iptables-fix.sh` (from the Istio lab,
   plus IPv6) accepts Kind bridge traffic in the legacy `FORWARD` chain.
6. **The "upgraded cluster" RBAC is emulated, not produced by a real upgrade.** A real 1.21→1.37
   upgrade is sixteen minor hops. Instead the lab writes the exact pre-1.22 rule
   (v1.21.14 `system:aggregate-to-edit`: write on core `endpoints`; diff against v1.22.0 in
   `results/rbac/`) into the role and then restarts the API server to show that bootstrap
   reconciliation keeps it, which is the mechanism that keeps it on upgraded clusters.
7. `/var/run/docker.sock` is world-writable on this throwaway VM so Kind runs without sudo.
