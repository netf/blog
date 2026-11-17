# Environment preflight: svcguard

## Status: BLOCKED before the first measurement

**The kube-proxy iptables arm cannot run on this VM's kernel.** The guest kernel (6.12.113+,
monolithic, supplied by the host) is built without the iptables `statistic` match
(`# CONFIG_NETFILTER_XT_MATCH_STATISTIC is not set`) and without `recent`
(`# CONFIG_NETFILTER_XT_MATCH_RECENT is not set`). kube-proxy's iptables mode uses
`-m statistic --mode random` to spread a Service across endpoints and `-m recent` for ClientIP
affinity. On the first lab cluster every sync failed:

```
Warning: Extension statistic revision 0 not supported, missing kernel module?
iptables-restore v1.8.9 (nf_tables):
line 61: RULE_APPEND failed (No such file or directory): rule in chain KUBE-SVC-ERIFXISQEP7F7OF4
"Sync failed" ipFamily="IPv4" retryingTime="30s"
```

`iptables-restore` is all-or-nothing, so this is not limited to multi-endpoint Services: from the
control-plane node the MetalLB webhook pod answered on its pod IP (HTTP 404) but its
single-endpoint ClusterIP timed out, the API server could not call the webhook, and MetalLB could
not be configured. Raw evidence: `results/preflight/blocker-kube-proxy-iptables.txt`. My first
preflight pass missed this because I did not list `xt_statistic` among the kernel options to
check; `scripts/01-preflight.sh` now prints it. (The Istio lab hit the same gap on this VM image
and moved to nftables mode.)

**Why it matters here:** the attack matrix is path × dataplane, and the pitch's surprise
candidate is that kube-proxy and eBPF dataplanes honour these fields differently. iptables is
still kube-proxy's default mode on Linux in v1.37.2 (`cmd/kube-proxy/app/server_linux.go`:
"No kube-proxy mode specified: defaulting to 'iptables'. Note that in Kubernetes 1.40 the default
mode will switch to 'nftables'"), so dropping it removes the column most readers would map to
their own cluster.

**What does work on this kernel (checked):**

- kube-proxy **nftables** mode: 0 sync errors; 30 requests from a node to a two-endpoint ClusterIP
  split 15/15 (`results/preflight/nftables-check.txt`).
- **Cilium v1.20.4 kube-proxy replacement**, with the deviations listed below (native routing, L7
  proxy off). ClusterIP routing through eBPF checked.

**Options (Piotr to choose):**

1. **Run the lab on a host whose kernel has `xt_statistic` and `xt_recent`** (any stock
   distribution kernel ships them as modules, e.g. Ubuntu `linux-image-generic`, a GitHub Actions
   `ubuntu-latest` runner, or a workstation). Nothing in the plan changes. That host would also
   have VXLAN, so Cilium could run in its default tunnel mode and deviation 1 below goes away.
   This is what I'd pick.
2. **Drop the iptables arm and run nftables + Cilium here.** Everything else in the plan runs as
   designed. The post would have to say plainly that iptables mode was not measured, and any
   dataplane-difference finding would be nftables vs eBPF only.
3. **Force the iptables arm to work by keeping every Service at one endpoint** (CoreDNS, the
   gateways, every chart scaled to 1). kube-proxy omits the `statistic` rule for single-endpoint
   Services, so the restore might succeed. I don't recommend it: it changes the cluster under
   test, the 25-chart false-positive run would break the dataplane the moment any chart runs two
   replicas, and ClientIP affinity would still fail.

The guest kernel can't be rebuilt or extended from inside the VM (`nomodule`, no `/lib/modules`).

---

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
| iptables `statistic`, `recent` matches | **not built**: blocks kube-proxy iptables mode (see Status) |
| iptables `CT` target, `xt_socket`, `TPROXY`, `multiport`, `physdev` | **not built** |
| `INET_UDP_DIAG` | **not built** (Cilium UDP socket termination) |
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
| Traefik | latest | v3.7.19 image on chart 42.4.0 (the chart's default is still v3.7.18) | v3.7.19 |
| MetalLB | (not pinned) | chart/app 0.16.2, L2 mode, frr-k8s disabled | 0.16.2 |
| Cilium CLI | | v0.20.3 | v0.20.3 |
| Helm | | v3.22.1 (v4.3.2 also exists; v3 kept to match the earlier labs) | |

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
