# Environment preflight: sakeyroll

## Status: STOPPED before the first measurement, two substitutions need approval

Nothing has been measured. No post has been written. The lab stops here until Piotr picks an
option for each blocker below.

### Blocker 1: kube-proxy iptables mode does not work on this kernel (the known issue)

The guest kernel (6.12.113+, monolithic, host-supplied, `nomodule`) is built without the
iptables `statistic` and `recent` matches and the `CT` target (`results/preflight/kconfig.txt`).
I reproduced it on the lab topology itself: Kind v0.33.0, `kindest/node:v1.37.2`, three control
planes and one worker, Kind's default kube-proxy mode. Every kube-proxy logged:

```
I1119 08:51:48.783954       1 server_linux.go:144] "Using iptables Proxier"
	exit status 4: Warning: Extension statistic revision 0 not supported, missing kernel module?
	line 30: RULE_APPEND failed (No such file or directory): rule in chain KUBE-SVC-NPX46M4PTMTKRN6Y
I1119 08:51:42.543658       1 proxier.go:660] "Sync failed" ipFamily="IPv4" retryingTime="30s"
```

`KUBE-SVC-NPX46M4PTMTKRN6Y` is the `kubernetes` Service. With three API servers it has three
endpoints, so it always needs the `statistic` rule. From a pod on the worker, 5 of 5 calls to
`https://kubernetes.default.svc/api` with the pod's projected token timed out after 5 s, and
`nslookup` found no DNS server (`results/preflight/blocker-kube-proxy-iptables.txt`).

**Why it matters here:** the lab's primary metric is authentication failures during rotation,
in-cluster and external. In iptables mode no pod can reach any API server at all, so there is
nothing to measure. kube-proxy is not the variable under test in this lab (signing, verification
and JWKS caching don't depend on the dataplane), but the three-API-server `kubernetes` Service is
how every in-cluster consumer presents its token, and its load balancing decides which API server
(rotated or not) a request lands on in the "one API server not yet updated" test.

**What works (checked):** kube-proxy **nftables** mode on the same topology, with a second
cluster running alongside: 0 `Sync failed` on all six kube-proxies, 30 of 30 pod-to-API-server
calls returned 200 through the three-endpoint ClusterIP, DNS resolved
(`results/preflight/nftables-check.txt`).

**Options:**

1. **Approve kube-proxy nftables mode on this VM** (`networking.kubeProxyMode: nftables` in
   both Kind clusters). This is what I'd pick for this lab, unlike svcguard where the dataplane
   was the experiment. The one thing it changes is how requests to the `kubernetes` Service are
   spread across the three API servers: nftables uses `numgen random` where iptables uses
   `statistic --mode random`. Both are per-connection random, so I expect the "one API server not
   yet updated" failure rate to come out the same, but I haven't measured iptables mode and the
   post would say nftables. Clients with long-lived HTTP/2 connections stick to one API server in
   either mode.
2. **Run the lab on a host with a stock distribution kernel** (any Ubuntu `linux-image-generic`,
   a GitHub Actions `ubuntu-latest` runner, a workstation). Nothing in the plan changes.
3. Not recommended: avoid multi-endpoint Services. Impossible here without dropping to one
   control plane, which removes the "one API server not yet updated" test.

### Blocker 2: real clock skew between nodes can't be produced on one VM

The pitch's failure tests include clock skew. All Kind nodes are containers on one kernel and
share its `CLOCK_REALTIME`. Time namespaces exist (`CONFIG_TIME_NS=y`, checked with
`unshare --time --boottime`), but they only offset the monotonic and boot-time clocks, not
the wall clock that JWT `iat`/`nbf`/`exp` checks use. libfaketime is available in Debian
(0.9.10), but the API server, kubelet and OpenBao are Go binaries that read the clock through
the vDSO and raw syscalls, so I expect `LD_PRELOAD` faketime not to affect them (not tested).

**Why it matters:** a skewed verifier is exactly the case where a freshly issued token is "not
yet valid" or an old-key token looks unexpired.

**Options:**

1. **Approve simulated skew**: the lab's own verifiers (mock STS, and the probe harness) take a
   clock offset, and for OpenBao the test uses tokens whose `iat`/`nbf`/`exp` are shifted by
   minting them with the stolen/rotated key at a chosen time, plus OpenBao's
   `clock_skew_leeway` role setting. The post would say skew was simulated at the verifier, not
   produced by a drifting node clock. This is what I'd pick.
2. Run the skewed verifier on a second VM whose clock is set by hand. Real skew, more setup.
3. Drop the clock-skew failure test.

### Smaller deviations (recorded, no decision needed unless you object)

- **No published `kindest/node:v1.37.2`.** Docker Hub has `v1.37.0` only. I built it locally
  with `kind build node-image --type release v1.37.2` from the official release tarballs (same
  as the svcguard lab): image ID `sha256:b83c29e5b276…`, Debian 13, containerd 2.3.4.
- **Repeated `extraArgs` collapse in Kind's kubeadm config.** Two `service-account-key-file`
  entries in a `ClusterConfiguration` patch came out as one in `/kind/kubeadm.conf`, and it
  replaced kubeadm's default `sa.pub`. The API server then verified only the new key while
  signing with the old one; the controller-manager logged `"Failed to list all nodes"
  err="Unauthorized"` and the second control plane could not join (`could not find a JWS
  signature in the cluster-info ConfigMap`). Evidence: `results/preflight/kind-collapsed-extraargs-*`.
  Consequence for the lab: clusters are created with stock flags, and every rotation step
  (all arms) edits the static pod manifests on each control plane, which is what a
  self-managed operator does anyway. A single PEM bundle in one `--service-account-key-file`
  works: the edited API server served two `kid`s from `/openid/v1/jwks` while its unedited peer
  served one (`results/preflight/pem-bundle-check.txt`). Arm B will use repeated flags in the
  manifest, as documented, not the bundle.
- **External signer is mutually exclusive with key files.** In v1.37.2
  `--service-account-signing-endpoint` cannot be combined with `--service-account-key-file`
  (`results/preflight/sources.md`). So in arm D the old file key's public half must be returned
  by the signer's `FetchKeys` during migration, and legacy Secret tokens (signed by the
  controller-manager's file key) need `exclude_from_oidc_discovery` entries there. This is a
  design consequence, not a blocker.
- **SoftHSM:** latest upstream is 2.7.0 (2026-01-20); Ubuntu 24.04 ships 2.6.1. The signer image
  will build 2.7.0 from source; the host's 2.6.1 is only for poking at tokens.
- **Host firewall:** Docker programs the Kind bridge in nf_tables, but a legacy `filter` table
  with `FORWARD DROP` also exists. Without `scripts/02b-host-iptables-fix.sh` (from the Istio and
  svcguard labs) the first 3-control-plane create failed: `dial tcp 172.18.0.6:6443: i/o timeout`
  to Kind's HA load balancer. The script must run after the `kind` Docker network exists.
- `/var/run/docker.sock` is world-writable on this throwaway VM so Kind runs without sudo.

---

Recorded 2026-11-19, 08:42 to 09:15 UTC. `scripts/01-preflight.sh` prints the raw facts
(`results/preflight/preflight.txt`).

## Compute

| What | Value | How checked |
|---|---|---|
| CPU | 4 vCPU | `nproc` |
| Memory | 15 GiB; at start `free` showed ~5 GiB available because a 10 GiB hypervisor balloon (`balloon_inflate` 2,621,440 pages) counts as used; RSS at start 0.9 GiB. With both preflight clusters up (3 CP + 1 worker, and 1 CP + 1 worker) the balloon had deflated 4 GiB, process RSS was 4.7 GiB and 6.7 GiB was available. | `free -h`, `/proc/vmstat`, `ps -eo rss=`, `docker stats` |
| Disk | 254 GB, 246 GB free; `/var/lib/docker` on the same disk | `df -h` |
| Virtualisation | `kvm` microVM (`reboot=k panic=1 nomodule`), PID 1 is `tini`, no systemd. Not a container; no nested virt. | `systemd-detect-virt`, `/proc/cmdline` |
| OS / kernel | Ubuntu 24.04.5, Linux 6.12.113+ | `/etc/os-release`, `uname -r` |
| Limits | `ulimit -n` 524288, `ulimit -u` 63994 | `ulimit` |
| Clock | No NTP daemon (no systemd, no chrony). SNTP offset against time.google.com: 0 s at 1 s resolution. | `scripts/01-preflight.sh` |

Cluster sizing: lab cluster A is 3 control planes + 1 worker (preflight create: 67 s to Ready),
cluster B is 1 control plane + 1 worker (28 s). Both fit at once with room for 50 small
workloads, OpenBao and the mock STS. If memory pressure shows up during the 50-workload run I'll
report it rather than shrink the workload count silently.

## Kernel

| What | Value |
|---|---|
| cgroups | v2 (`cgroup2fs`), controllers `cpuset cpu io memory hugetlb pids` |
| Modules | monolithic: no `/lib/modules`, `/proc/modules` empty |
| `br_netfilter`, `overlay`, `nf_conntrack`, `nf_tables` (+ `nft_numgen`, `nft_ct`, `nft_nat`, `nft_fib_inet`) | built in |
| iptables | 1.8.10, `nf_tables` backend, plus a legacy `filter` table with `FORWARD DROP` |
| nftables usable | yes (created and deleted a table with a hook chain; `nft` 1.0.9) |
| iptables `statistic`, `recent`, `CT` | **not built** (Blocker 1) |
| Time / user namespaces | `CONFIG_TIME_NS=y`, `CONFIG_USER_NS=y` (Blocker 2 for what time ns can't do) |
| netns / tc | `ip netns add` + `tc qdisc add clsact`: OK with sudo |
| Sysctls changed by the lab | `fs.inotify.max_user_watches=524288`, `fs.inotify.max_user_instances=512` (Kind multi-node). `net.ipv4.ip_forward=1` and `bridge-nf-call-iptables=1` were already set. |

## Container tooling and versions (pinned on lab day, before any measurement)

| Component | Pitch pin | Used | Latest on 2026-11-19 |
|---|---|---|---|
| Kubernetes | v1.37.2 | v1.37.2 (kubectl and locally built node image) | v1.37.2 (v1.38.0-beta.0 is a pre-release) |
| Kind | v0.33.0 | v0.33.0 (built with go1.26.7) | v0.33.0 |
| OpenBao | v2.7.2 | v2.7.2 CLI (`bao`); images `quay.io/openbao/openbao:2.7.2` and `docker.io/openbao/openbao:2.7.2` exist | v2.7.2 |
| SoftHSM | latest | 2.7.0 planned in the signer image (source tarball reachable); host apt has 2.6.1 | 2.7.0 |
| Go | latest stable | go1.27.4 | go1.27.4 |
| Docker | | 29.10.0 client and server, rootful, overlayfs, cgroupfs driver, cgroup v2, iptables firewall backend; started by hand (`scripts/00b-start-dockerd.sh`) | |
| Helm | | v3.22.1 (v4.3.2 exists; v3 kept to match the earlier labs) | |
| jq / nftables / iptables / opensc | | 1.7 / 1.0.9 / 1.8.10 / 0.25.0~rc1 (apt) | |

Install: `scripts/00-tools.sh`. Throwaway checks: one 3-control-plane cluster in default mode
(Blocker 1), then the 3-control-plane and the 2-node cluster at the same time in nftables mode;
all deleted afterwards.

## Network

Docker Hub, ghcr.io, quay.io and registry.k8s.io answered 401 (reachable, auth challenge);
dl.k8s.io, proxy.golang.org, the OpenBao Helm repo, deb.debian.org and the SoftHSM 2.7.0 source
tarball answered 200/302. Pods in nftables mode reached the API server and resolved DNS. netns and
tc are permitted.
