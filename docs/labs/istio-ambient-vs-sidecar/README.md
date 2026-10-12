# Lab: Istio ambient vs sidecar on Kind

Reproduction kit for the post
[Istio ambient vs sidecar, measured on Kind](../../../src/content/blog/istio-ambient-vs-sidecar-on-kind.md).
Every number in the post comes from the files under `results/`, produced by the scripts here.

## What it builds

- Kind cluster `mesh-lab`: 1 control plane + 2 workers, Kubernetes v1.36.4, kube-proxy in
  nftables mode (`kind-config.yaml`).
- Istio installed with Helm from the release-tarball charts, `profile=ambient`, so one istiod
  serves both data planes. Starts on 1.30.5 and is upgraded in place to 1.31.1 under load.
- Four namespaces with identical fortio client/server pairs, client pinned to `mesh-lab-worker`,
  server pinned to `mesh-lab-worker2`:

| namespace    | data plane                              |
| ------------ | --------------------------------------- |
| `baseline`   | none                                    |
| `sidecar`    | `istio-injection=enabled`               |
| `ambient`    | `istio.io/dataplane-mode=ambient`       |
| `ambient-wp` | ambient + namespace waypoint (`istioctl waypoint apply --enroll-namespace`) |

## Versions used

See `results/versions.txt`. Summary: Ubuntu 24.04.5 host (kernel 6.12.94+, 4 vCPU, ~5 GB usable
RAM), Docker 29.9.0, Kind v0.33.0, kindest/node v1.36.4, kubectl v1.37.1, Helm v3.22.0,
Istio 1.30.5 then 1.31.1, Gateway API v1.5.1, fortio 1.76.0.

## Run order

```bash
cd docs/labs/istio-ambient-vs-sidecar
./scripts/00-tools.sh                     # kind, kubectl, helm, istioctl, both Istio tarballs
kind create cluster --config kind-config.yaml
./scripts/01b-host-iptables-fix.sh        # only if both iptables backends are active (see below)
./scripts/01a-preload-images.sh           # only if Kind nodes cannot pull from the internet
./scripts/01-cluster-and-istio.sh 1.30.5
./scripts/02-workloads.sh
./scripts/03-upgrade-under-load.sh        # 1.30.5 -> 1.31.1 with traffic flowing
./scripts/04-restart-under-load.sh        # run 3 times; the post uses results/restart/run{1,2,3}
python3 scripts/bench.py fixed 3          # ~17 min
python3 scripts/bench.py max 3            # ~9 min
python3 scripts/bench.py noka 3           # ~9 min
python3 scripts/summarize.py > results/bench/summary.md
./scripts/05-mtls.sh
./scripts/06-l7-retries-authz.sh          # retries; its authz part waits only 10s, see 06b
./scripts/06b-authz-propagation.sh
./scripts/06c-ztunnel-http-deny.sh
./scripts/07-outbound.sh
./scripts/08-scale-memory.sh
./scripts/09-ztunnel-failure.sh           # run 3 times; the post uses run1..run3
./scripts/10-istiod-outage.sh
```

Run benchmarks with nothing else happening on the cluster. `bench.py` interleaves the four modes
in each round and reads CPU counters through `crictl stats` (containerd reads the cgroup at
request time) rather than the kubelet summary API (cached).

## Environment workarounds (all were needed on the lab VM)

1. **No egress from Kind nodes** - images are pulled on the host and side-loaded.
   `kind load docker-image` fails on multi-arch images with Docker's containerd image store
   (`ctr: content digest ... not found`), so `01a-preload-images.sh` saves single-platform
   archives with `docker save --platform linux/amd64` and uses `kind load image-archive`.
2. **`registry.istio.io` unreachable** - charts are installed with `hub=docker.io/istio`
   (the ztunnel chart reads top-level `hub`, the others `global.hub`; both are set).
3. **Two iptables backends** - the legacy `filter` table had `FORWARD DROP`, which dropped
   node-to-node traffic (kubelet `:10250` timeouts). `01b-host-iptables-fix.sh` adds accept and
   masquerade rules for the Kind bridge.
4. **Kernel without the iptables `statistic` match** - kube-proxy in iptables mode failed to
   program multi-endpoint Services (CoreDNS was unreachable over its ClusterIP). Fixed with
   `kubeProxyMode: nftables` in `kind-config.yaml`.
5. **Kernel without ipset** - the ambient CNI agent failed with
   `error initializing host addressSet manager: invalid argument`. Fixed with
   `global.nativeNftables=true` on istiod and istio-cni (this also switches `istio-init` for
   sidecars to `--native-nftables`).
6. **1.31.1 Helm charts not published** to `istio-release.storage.googleapis.com/charts` or
   `oci://gcr.io/istio-release/charts` at the time of the run; the charts inside the release
   tarballs are used for both versions.

## Results layout

```text
results/
  versions.txt                 exact versions and node info
  install-1.30.5.log           Helm install output
  upgrade/                     03: fortio JSON per namespace, timeline, proxy-status after
  restart/run{1,2,3}/          04: server rollout under load
  bench/                       fixed|max|noka .jsonl (one line per run) and summary.md
  mtls/                        05: wire capture analysis, TLS handshakes, identities, STRICT
  l7/                          06/06b/06c: retries, authz propagation, ztunnel HTTP-only DENY
  outbound/                    07: ALLOW_ANY / REGISTRY_ONLY / ServiceEntry
  scale/                       08: config fan-out and pod density memory
  ztunnel-failure/run{1,2,3}/  09: graceful delete and SIGKILL of the client-node ztunnel
  istiod-outage/               10: run1 (first script version) and the final run
```

## Cleanup

```bash
kind delete cluster --name mesh-lab
docker rm -f ext-http
```
