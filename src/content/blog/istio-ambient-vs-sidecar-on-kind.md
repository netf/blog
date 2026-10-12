---
title: 'Istio ambient vs sidecar, measured on Kind'
description: 'Latency, CPU, memory, mTLS on the wire, L7 semantics, upgrades and failure modes of Istio 1.31 ambient and sidecar modes, with every claim backed by a reproducible Kind experiment.'
pubDate: 2026-10-12
tags: ['kubernetes', 'istio', 'service-mesh', 'benchmarks']
---

Most ambient-vs-sidecar comparisons are either vendor benchmarks or architecture diagrams. I wanted
something narrower and more useful: run both data planes side by side on the same cluster, under the
same control plane, and write down only what I actually observed. Everything below comes from a
Kind lab. The scripts, raw fortio JSON and logs are in the repo under
[`docs/labs/istio-ambient-vs-sidecar/`](https://github.com/netf/blog/tree/main/docs/labs/istio-ambient-vs-sidecar).

Where I expected one thing and saw another, I say so. Where I could not test something, I say that
too.

## TL;DR

On this lab (one 4 vCPU VM, Istio 1.31.1, Kubernetes 1.36.4):

- **Ambient at L4 is much cheaper than sidecars.** At a fixed 1,000 req/s it added 0.39 ms to p50
  latency (sidecar: 1.40 ms), used 0.077 data-plane cores (sidecar: 0.206), and reached 3.6x the
  sidecar's closed-loop throughput on the same CPU budget.
- **Ambient plus a waypoint is not cheaper than sidecars on latency.** Once L7 is in the path, p50
  was 1.90 ms versus 1.63 ms for sidecars. CPU was lower (0.156 vs 0.206 cores) and throughput was
  similar.
- **Memory scales differently.** Each sidecar used about 28 MiB and grew to about 69 MiB when 200
  unrelated Services were added to the mesh. A ztunnel used 4 to 7 MiB per node and grew by under
  1 MiB in the same test.
- **The semantics differ, and some of the differences are silent.** Without a waypoint, a
  VirtualService retry policy was ignored. An HTTP-path DENY policy was not enforced at all (fail
  open), even though the policy's status said it would be enforced more restrictively.
  `REGISTRY_ONLY` blocked unknown destinations for sidecars but not for ambient pods, with or
  without a waypoint, and a waypoint-bound ServiceEntry only captured traffic sent to its VIP.
- **Upgrades are decoupled from app restarts in ambient, but not free.** A ztunnel restart closed
  every app connection through it at the 25 s drain deadline. A waypoint rollout triggered by the
  istiod upgrade dropped 16 of 30,000 requests. The sidecars stayed on the old proxy until their
  pods were restarted.
- **The failure domains are different.** Killing a ztunnel broke traffic for every ambient pod on that
  node for 0.16 to 1.1 s, and every failed request failed at DNS. With istiod down, sidecar pods
  could not be created at all, while new ambient pods became Ready but could not receive traffic.

## Lab setup

| component      | version / detail                                                      |
| -------------- | --------------------------------------------------------------------- |
| host           | Ubuntu 24.04.5, kernel 6.12.94+, 4 vCPU, ~5 GB usable RAM             |
| Docker         | 29.9.0                                                                |
| Kind           | v0.33.0, node image `kindest/node:v1.36.4` (pinned by digest)         |
| Kubernetes     | v1.36.4, kindnet CNI, kube-proxy in **nftables** mode                 |
| Istio          | 1.30.5, upgraded in place to 1.31.1, Helm, `profile=ambient`          |
| Gateway API    | v1.5.1 CRDs                                                           |
| load generator | fortio 1.76.0, running inside the client pod                          |

Kubernetes 1.36 is the newest minor version that both Istio 1.30 and 1.31 support, according to
[Istio's support matrix](https://istio.io/latest/docs/releases/supported-releases/). That overlap
is what made the in-place upgrade test valid.

The cluster has one control-plane node and two workers. Every client pod is pinned to
`mesh-lab-worker` and every server pod to `mesh-lab-worker2`, so all measured traffic crosses nodes.
One istiod serves four namespaces running identical fortio client/server pairs:

| namespace    | data plane                                          |
| ------------ | --------------------------------------------------- |
| `baseline`   | none                                                |
| `sidecar`    | `istio-injection=enabled`                           |
| `ambient`    | `istio.io/dataplane-mode=ambient` (ztunnel only)    |
| `ambient-wp` | ambient plus a namespace waypoint (Envoy, L7)       |

The install, trimmed (full script: `scripts/01-cluster-and-istio.sh`):

```bash
CHARTS=/tmp/istio-1.30.5/manifests/charts
HUB=(--set global.hub=docker.io/istio --set hub=docker.io/istio --set global.variant=distroless --set variant=distroless)
NFT=(--set global.nativeNftables=true)
helm upgrade --install istio-base "$CHARTS/base" -n istio-system --create-namespace "${HUB[@]}" --wait
helm upgrade --install istiod "$CHARTS/istio-control/istio-discovery" -n istio-system --set profile=ambient "${HUB[@]}" "${NFT[@]}" --wait
helm upgrade --install istio-cni "$CHARTS/istio-cni" -n istio-system --set profile=ambient "${HUB[@]}" "${NFT[@]}" --wait
helm upgrade --install ztunnel "$CHARTS/ztunnel" -n istio-system "${HUB[@]}" --wait
istioctl waypoint apply -n ambient-wp --enroll-namespace --wait
```

What each mode actually put into the pods (from the pod specs):

- **Sidecar** pods get an `istio-init` init container that runs as root with `NET_ADMIN` and
  `NET_RAW` and calls `istio-iptables ... --native-nftables`. They also get `istio-proxy` as a native
  sidecar (an init container with `restartPolicy: Always`) requesting **100m CPU / 128Mi**, with
  limits of 2 CPU / 1Gi.
- **Ambient** pods get no extra containers, only the annotation
  `ambient.istio.io/redirection: enabled`. The per-node ztunnel DaemonSet requests **200m CPU /
  512Mi**.

Each mode also leaves a visible fingerprint on a plain HTTP request:

```text
sidecar     server: envoy, X-Forwarded-Client-Cert: By=spiffe://cluster.local/ns/sidecar/sa/server;...;URI=spiffe://cluster.local/ns/sidecar/sa/client
ambient     (nothing added)
ambient-wp  server: istio-envoy, x-envoy-decorator-operation: server.ambient-wp.svc.cluster.local:8080/*
```

### Environment problems I had to work around

These are properties of my lab VM, not of Istio, but they change the configuration, so they belong
here:

1. **The Kind nodes had no internet egress.** Images were pulled on the host and side-loaded.
   `kind load docker-image` failed on multi-arch images (`ctr: content digest ... not found`), so I
   used `docker save --platform linux/amd64` with `kind load image-archive` instead.
2. **`registry.istio.io` (the chart default hub) was unreachable**, so I used `docker.io/istio`.
   The ztunnel chart reads the top-level `hub` value, not `global.hub`.
3. **Both iptables backends were active on the host.** A legacy `filter` table with `FORWARD DROP`
   silently dropped node-to-node traffic, and the first symptom was `kubectl logs` timing out on
   `:10250`.
4. **The kernel lacks the iptables `statistic` match.** kube-proxy in iptables mode logged
   `Extension statistic revision 0 not supported` and could not program any Service with more than
   one endpoint, so CoreDNS was unreachable over its ClusterIP. I switched to
   `kubeProxyMode: nftables`.
5. **The kernel lacks ipset.** The ambient CNI agent crashed with
   `error initializing host addressSet manager: invalid argument`. Setting
   `global.nativeNftables=true` fixed it. I set it on istiod too, so sidecar redirection also uses
   nftables. **Both data planes in this post run on the non-default nftables backend.**
6. **The 1.31.1 Helm charts were not published** to the classic Helm repo or to
   `oci://gcr.io/istio-release/charts` when I ran this, even though the 1.31.1 images were on
   Docker Hub. I installed both versions from the charts inside the release tarballs.

## Methodology

- **Load:** fortio runs inside the client pod (`kubectl exec deploy/client -- fortio load`) against
  `http://server:8080/echo`, using HTTP/1.1 with tiny payloads and 10 µs histogram resolution.
- **Scenarios:** I ran three, each repeated over 3 rounds, with the mode order rotated each round so
  slow drift on the shared VM hit every mode:
  - **fixed:** 1,000 req/s over 16 keep-alive connections for 60 s;
  - **max:** closed loop (`-qps 0`), 16 connections, 30 s;
  - **noka:** 200 req/s over 4 connections with `-keepalive=false`, so every request opens a new
    TCP connection.
- **Warm-up:** 5 s at the same settings before every measured run, discarded.
- **CPU:** cumulative `usageCoreNanoSeconds` from `crictl stats` on both workers, snapshotted
  right before and right after each run. containerd reads the cgroup at request time, while the
  kubelet summary API is cached, so this is more precise. The delta is divided by fortio's actual
  run duration. "Data-plane cores" means both sidecars, both ztunnels, or both ztunnels plus the
  waypoint. I also report each worker node's total cgroup CPU.
- **Memory:** container working set from the same API.
- **Reported values:** the median across rounds, with min to max in brackets.

The numbers are only comparable to each other. The load generator, both workers, the control plane
and Docker all share the same 4 vCPUs. The closed-loop "max" scenario saturates the box, so read it
as CPU per request, not capacity.

## Results: latency

**Fixed 1,000 req/s, 16 keep-alive connections, 60 s** (ms, median of 3, min to max; zero non-200
responses in all 12 runs):

| mode       | p50              | p90              | p99              | p99.9            |
| ---------- | ---------------- | ---------------- | ---------------- | ---------------- |
| baseline   | 0.23 (0.22-0.23) | 0.34 (0.34-0.35) | 0.56 (0.53-0.56) | 1.63 (1.35-3.18) |
| sidecar    | 1.63 (1.52-1.69) | 2.00 (1.89-2.32) | 2.59 (2.48-3.44) | 5.73 (5.17-7.05) |
| ambient    | 0.62 (0.61-0.64) | 0.89 (0.87-0.91) | 1.38 (1.30-1.39) | 2.34 (1.89-3.29) |
| ambient-wp | 1.90 (1.86-1.92) | 2.41 (2.38-2.43) | 2.92 (2.91-2.99) | 5.07 (4.35-5.65) |

Compared with the baseline, the added p50 latency was **+0.39 ms for ambient, +1.40 ms for
sidecar, and +1.67 ms for ambient with a waypoint**. At p99 the additions were +0.82, +2.03 and
+2.36 ms.

**New connection per request, 200 req/s** (ms):

| mode       | p50  | p90  | p99  | p99.9 |
| ---------- | ---- | ---- | ---- | ----- |
| baseline   | 0.82 | 1.05 | 1.58 | 7.50  |
| sidecar    | 1.80 | 2.35 | 2.93 | 5.50  |
| ambient    | 1.34 | 1.78 | 2.44 | 4.43  |
| ambient-wp | 2.38 | 2.96 | 3.71 | 6.00  |

Here the gap between ambient and sidecar narrows from 1.01 ms to 0.46 ms at p50. Neither mode
appears to do a TLS handshake per app connection. In the packet capture below, five separate
`fortio curl` invocations produced two TLS handshakes for sidecar and one for ambient, so both
proxies pool their node-to-node mTLS connections. What remains is the cost of each new app
connection to the local proxy.
The baseline p99.9 varied from 2.50 to 7.75 ms between rounds, so I would not read anything into
the p99.9 column of this table.

**Closed loop, 16 connections, 30 s:**

| mode       | achieved req/s         | p50 ms | p99 ms |
| ---------- | ---------------------- | ------ | ------ |
| baseline   | 103,210 (87,228-108,184) | 0.11   | 0.92   |
| sidecar    | 11,529 (10,086-11,695) | 1.29   | 3.45   |
| ambient    | 40,962 (34,054-41,505) | 0.35   | 1.22   |
| ambient-wp | 12,932 (11,753-13,909) | 1.15   | 2.82   |

## Results: CPU and memory

**Fixed 1,000 req/s.** Cores are averaged over the 60 s run, median of 3.

| mode       | data-plane cores | breakdown                                   | both workers, total |
| ---------- | ---------------- | ------------------------------------------- | ------------------- |
| baseline   | 0                | -                                           | 0.142               |
| sidecar    | 0.206            | client sidecar 0.106, server sidecar 0.100  | 0.337               |
| ambient    | 0.077            | ztunnel client node 0.041, server node 0.036 | 0.209               |
| ambient-wp | 0.156            | waypoint 0.088, ztunnels 0.038 + 0.029       | 0.284               |

Normalized to data-plane millicores per 1,000 req/s:

| mode       | fixed (1k rps) | max (closed loop) | noka (new conn per request) |
| ---------- | -------------- | ----------------- | --------------------------- |
| sidecar    | 206            | 186               | 557                         |
| ambient    | 77             | 40                | 566                         |
| ambient-wp | 156            | 121               | 651                         |

Two things stood out. First, ztunnel's cost per request fell by half at high rates (77 down to 40
millicores per 1k req/s), while the sidecars' barely changed. Second, with a new connection per
request, sidecar and ztunnel cost almost exactly the same. Ambient's L4 advantage in this lab came
from per-request work on long-lived connections, not from connection handling.

**Memory**, as working set:

| what                                              | sidecar (each)    | ztunnel (each node)   | waypoint            |
| ------------------------------------------------- | ----------------- | --------------------- | ------------------- |
| fresh, idle                                       | 28.3 / 29.3 MiB   | 4.2 / 4.3 MiB         | 25.3 MiB            |
| after the benchmark runs                          | 27.5-29.2 MiB     | 5.8-7.2 MiB           | 93 MiB              |
| +200 Services (400 ports) in an unrelated namespace | **68.6 / 68.8 MiB** | **4.9 / 5.0 MiB**   | 25.9 MiB            |
| Envoy clusters / ztunnel services after fan-out   | 22 → 422 clusters | 8 → 208 services      | 10 → 10 clusters    |

The fan-out test is the one to remember. Every sidecar received configuration for every Service in
the mesh and paid about 40 MiB for 200 Services that its workload never talks to. That is the
default behavior; I did not test scoping it down with the `Sidecar` resource. ztunnel also learned
all 200 Services but only grew by about 0.7 MiB. The waypoint only learned about its own namespace.

Envoy did not hand the memory back. After I deleted the 200 Services and re-ran the test without
restarting pods, the "before" sample showed the client sidecar at 89.7 MiB and the server sidecar
at 66.4 MiB (`results/scale/memory-fanout-rerun-without-restart.tsv`). The 93 MiB waypoint figure
is the same effect, left over from the closed-loop benchmark. A freshly restarted waypoint used
25 MiB.

**Pod density.** Scaling the server to 10 replicas (one mode at a time):

- sidecar: 9 new `istio-proxy` containers at 27.8-29.0 MiB each, so about 257 MiB added;
- ambient: the server-node ztunnel went from 4.8 to 6.1 MiB, so 1.3 MiB added.

Requests matter more than usage for scheduling. Each sidecar pod in this lab requested 200m CPU (app
100m + proxy 100m) against 100m for the ambient pod, plus 200m per node for ztunnel. In my first
attempt I scaled both namespaces to 10 replicas on the same 4-CPU worker. The node hit 100% CPU
requested, and two ambient replicas stayed `Pending` with
`0/3 nodes are available: 1 Insufficient cpu` (`results/scale/scheduling-side-effect.txt`). With
these default requests, ztunnel's 512Mi equals the memory reservation of four sidecars, and its
200m equals the CPU reservation of two.

## Results: mTLS on the wire

I captured traffic on the server node's `eth0` with tcpdump while each client sent five requests
carrying the header `X-Lab-Marker: PLAINTEXT-CANARY-42`. The client pods were restarted first so
the capture would include fresh handshakes.

| mode       | marker packets | port on the wire | ClientHello SNI / ALPN                    | TLS     |
| ---------- | -------------- | ---------------- | ----------------------------------------- | ------- |
| baseline   | 5              | 8080             | none (plaintext)                          | -       |
| sidecar    | 0              | 8080             | `outbound_.8080_._.server.sidecar...` / `istio-http/1.1,istio,http/1.1` | 1.3 |
| ambient    | 0              | 15008            | no SNI / `h2`                             | 1.3     |
| ambient-wp | 0              | 15008            | no SNI / `h2`                             | 1.3     |

The full sidecar SNI was `outbound_.8080_._.server.sidecar.svc.cluster.local`. "Port on the wire" is
the destination port of every packet from the client node to the server node during the capture.

Sidecar-to-sidecar traffic kept the classic Istio mTLS on the destination port. Ambient traffic,
including the client-to-waypoint hop, moved to HBONE on port 15008. ztunnel lists the sidecar pods
as `HBONE` in `istioctl ztunnel-config workloads`, but sidecar-to-sidecar traffic still used 8080 on
the wire. I did not test sidecar-to-ambient traffic.

Identity is visible in both modes. The sidecar server received the XFCC header shown earlier.
ztunnel writes both SPIFFE IDs to its access log:

```text
info access connection complete src.workload="client-b66f74955-rqhgg" src.identity="spiffe://cluster.local/ns/ambient/sa/client"
  dst.addr=10.244.2.24:15008 dst.hbone_addr=10.244.2.24:8080 dst.service="server.ambient.svc.cluster.local"
  dst.identity="spiffe://cluster.local/ns/ambient/sa/server" direction="inbound" bytes_sent=75 bytes_recv=79 duration="2ms"
```

With a mesh-wide `PeerAuthentication` in `STRICT` mode, a plaintext request from the non-mesh
`baseline` client was rejected by all three meshed servers with `connection reset by peer`. With
the policy deleted (PERMISSIVE), the same plaintext request to the ambient server returned 200.

## Results: L7 behavior, retries and authorization

### Retries

The fortio server returns 503 for about half of requests when called with `?status=503:50`. Each
cell below is the number of 503s out of 2,000 requests at 100 req/s:

| configuration                                     | sidecar               | ambient            | ambient-wp            |
| ------------------------------------------------- | --------------------- | ------------------ | --------------------- |
| no VirtualService                                 | 993 (49.7%)           | 938 (46.9%)        | 1000 (50.0%)          |
| VirtualService `retries: {attempts: 5, retryOn: 5xx}` | **31 (1.55%)**, p99 360 ms | **1009 (50.5%)** | **34 (1.7%)**, p99 365 ms |
| VirtualService `retries: {attempts: 0}`           | 1025                  | 994                | 993                   |

I expected Istio's default retry policy to retry 503s. It did not. The route that istiod generated
for the sidecar has `numRetries: 2` and
`retryOn: connect-failure,refused-stream,unavailable,cancelled,retriable-status-codes`, but it lists
no retriable status codes, so a 503 response is passed straight through.

With an explicit policy, the sidecar and the waypoint behaved almost exactly as the math predicts:
0.5<sup>6</sup> ≈ 1.56% of requests fail all six attempts. The retries cost tail latency: p99 rose
from 3 to 4 ms to about 360 ms, which I attribute to Envoy's retry backoff. **Without a waypoint,
the VirtualService was silently ignored.** It applied cleanly, nothing complained, and 50% of
requests still failed.

### Authorization

The test policy was `action: DENY` with a single rule, `to.operation.paths: ["/debug"]`. For
sidecar and ambient it was attached with `selector: app=server`. For the waypoint it was attached
with `targetRefs` to the Service. I applied it, then polled once per second until `/debug` stopped
returning 200, over three rounds per mode:

| mode       | time until `/debug` returned 403 | `/echo` afterwards |
| ---------- | -------------------------------- | ------------------ |
| sidecar    | 1.2 s, 3.4 s, 2.3 s              | 200                |
| ambient-wp | 1.2 s, 1.2 s, 1.2 s              | 200                |
| ambient    | **never** (still 200 after 90 polls, in all 3 rounds) | 200 |

In one earlier ad-hoc attempt, the sidecar took 15 to 20 s to start returning 403, and my first
scripted run checked after a fixed 10 s and saw 200. I could not reproduce that delay in the three
timed rounds above. Do not assume policy propagation is instant: verify it.

The ambient result is the most important finding in this post. istiod wrote this status onto the
policy:

```text
ZtunnelAccepted=True reason=UnsupportedValue: ztunnel does not support HTTP attributes (found: paths).
In ambient mode you must use a waypoint proxy to enforce HTTP rules. DENY policy with HTTP attributes
is enforced without the HTTP rules. This will be more restrictive than requested.
```

`kubectl apply` also printed `will deny all traffic to TCP ports under its scope`. I read both as
"everything to this workload will be denied". **What actually happened is that nothing was denied.**
`/debug` and `/echo` both returned 200, including from a brand-new pod with a different service
account and no pooled connections. The policy that reached ztunnel was:

```json
{"name":"deny-debug","namespace":"ambient","scope":"WorkloadSelector","action":"Deny","rules":[[[{}]]]}
```

ztunnel does enforce policy in general. An L4-only DENY on
`principals: ["cluster.local/ns/ambient/sa/client"]` reset the `client` service account's
connections, and a pod using the `default` service account still got 200. The behavior is explained
by ztunnel 1.31.1's `src/rbac.rs`. `Authorization::matches` skips an empty match inside a clause
(`if mg.is_empty() { continue; }`), so a clause whose only match is `{}` never matches, and a DENY
built from it never fires. So an HTTP-only DENY bound to ztunnel fails open, which is the opposite
of what the status message says. If you run ambient without waypoints, either never write HTTP
attributes into policies, or treat `ZtunnelAccepted=...UnsupportedValue` as a blocking error in
CI.

## Results: outbound traffic

The external target was a fortio container on the Kind Docker network (172.18.0.5:8080), which is
outside the cluster and outside the mesh. Each mesh client called it by IP. `REGISTRY_ONLY` below
means `meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY`, set mesh-wide through Helm:

| outbound policy                | baseline | sidecar | ambient | ambient-wp |
| ------------------------------ | -------- | ------- | ------- | ---------- |
| `ALLOW_ANY` (default)          | 200      | 200     | 200     | 200        |
| `REGISTRY_ONLY`                | 200      | **502** | **200** | **200**    |
| `REGISTRY_ONLY` + ServiceEntry | 200      | 200     | 200     | 200        |

`REGISTRY_ONLY` is enforced by the sidecar and not by ztunnel. It was not enforced in the waypoint
namespace either: unregistered destinations passed straight through.

Getting traffic to an external host through the waypoint depended on how the ServiceEntry was
written. Istio's [egress gateway docs for ambient](https://istio.io/latest/docs/ambient/usage/egress-gateway/)
say that a ServiceEntry in a waypoint-enrolled namespace is routed through the waypoint
automatically. I created two ServiceEntries in `ambient-wp`, and both reported
`istio.io/WaypointBound=True`:

| ServiceEntry                                       | called as     | through the waypoint?                                               |
| -------------------------------------------------- | ------------- | ------------------------------------------------------------------- |
| `addresses: [172.18.0.5/32]`, endpoint 172.18.0.5  | hostname      | **no**: no Envoy headers; ztunnel logged `dst.workload="ext-http"`  |
| same                                               | IP            | **no**                                                              |
| no `addresses` (istiod auto-allocated 240.240.0.x) | hostname      | **yes**: `server: istio-envoy`, `x-envoy-decorator-operation`        |
| same                                               | IP 172.18.0.5 | **no**                                                              |

ztunnel's service table did list the first ServiceEntry with `waypoint: ambient-wp/waypoint`, yet
its access log showed a direct outbound connection to `172.18.0.5:8080`, attributed to the
ServiceEntry's endpoint workload. My reading is that ztunnel matched the destination IP to the
endpoint workload before it considered the service and its waypoint. That is an inference from the
log, not something I traced in the source. The practical consequence holds either way. In ambient,
the waypoint only sees egress that is addressed to the ServiceEntry's VIP. A pod that connects to
the external IP directly bypasses it, and `REGISTRY_ONLY` does not stop it. I did not test
NetworkPolicy or the docs' dedicated `istio-egress` namespace as ways to close that gap.

## Results: upgrades and restarts

### In-place upgrade from 1.30.5 to 1.31.1 under load

Each meshed namespace carried 100 req/s over 4 keep-alive connections for 300 s while I ran
`helm upgrade` on base, istiod, istio-cni and ztunnel in that order:

```text
14:45:21.515 load started (300s, 100 qps, 4 conns) in sidecar ambient ambient-wp
14:45:43.627 helm upgrade istiod
14:45:46.495 istiod done
14:46:06.499 helm upgrade istio-cni
14:46:30.892 istio-cni done
14:46:50.897 helm upgrade ztunnel
14:47:21.173 ztunnel done
```

| namespace  | requests | failed               | sockets used | max latency | what happened                                                                                                     |
| ---------- | -------- | -------------------- | ------------ | ----------- | ----------------------------------------------------------------------------------------------------------------- |
| sidecar    | 30,000   | 0                    | 4            | 9 ms        | nothing; proxies still on 1.30.5 afterwards                                                                        |
| ambient    | 30,000   | 0                    | 8            | 8 ms        | all 4 connections closed at 14:47:18 (ztunnel upgrade); fortio reconnected transparently                           |
| ambient-wp | 30,000   | **16**               | 28           | **3,002 ms** | waypoint rolled to 1.31.1 right after istiod; resets at 14:45:50.99, 4 requests hit the 3 s timeout, then the ztunnel close at 14:47:19 |

After the upgrade, `istioctl proxy-status` showed exactly the split you would expect:

```text
client-85d8795866-r7jw5.sidecar      ...  1.30.5
server-74f4f4cff6-kbwx2.sidecar      ...  1.30.5
waypoint-f587fbfc4-4268n.ambient-wp  ...  1.31.1
ztunnel-5jdzk.istio-system           ...  1.31.1   (x3)
```

The istiod upgrade also upgraded the waypoint. The waypoint is a Deployment that istiod manages,
and a new ReplicaSet with the 1.31.1 image appeared as soon as the new istiod came up. With the default single
replica, that rollout dropped requests. I did not test a waypoint with 2+ replicas and a
PodDisruptionBudget.

### Finishing a sidecar upgrade: restarting pods under load

Sidecars need a pod restart to pick up a new proxy. I rolled the server Deployment
(`kubectl rollout restart`) in every namespace under 100 req/s. The fortio server has one replica
and no preStop hook, so this mostly measures the app's own shutdown, not the mesh:

| run | baseline              | sidecar               | ambient               | ambient-wp                  |
| --- | --------------------- | --------------------- | --------------------- | --------------------------- |
| 1   | 4 errors, max 8 ms    | 9 x 503, max 75 ms    | 12 errors, max 3,001 ms | 12 x 503, max 13 ms       |
| 2   | 8 errors, max 3 ms    | 8 x 503, max 69 ms    | 16 errors, max 3,002 ms | 4 errors + 11 x 503, max 3,003 ms |
| 3   | 20 errors, max 3,001 ms | 6 x 503, max 68 ms  | 8 errors, max 18 ms   | 4 errors + 8 x 503, max 3,002 ms |

Out of 6,000 requests per run, every mode, including no mesh at all, lost a handful. I would not
rank them on these counts. What was consistent was the failure shape. The sidecar always failed
fast with a 503 from Envoy, and never took longer than 75 ms. Every other mode hit the client's 3 s
timeout in at least one run. The error types also differed. The ambient client's errors were
always `connection reset by peer` or `i/o timeout`, never `connection refused`, which fits its
connection being accepted locally by ztunnel before the backend is known to be gone. The
baseline's errors were `connection refused`, plus timeouts in run 3.

## Results: failure modes

### Losing the node-local proxy

All three meshed clients run on `mesh-lab-worker`. Under 100 req/s each, I removed that node's
ztunnel in two ways, three runs each:

- **Graceful (`kubectl delete pod`):** 0 errors in every namespace in all 3 runs. The sidecar kept
  its 4 sockets. Both ambient namespaces went from 4 to 8, because every connection was closed once.
  The old ztunnel's log shows why:

  ```text
  16:28:36.247557Z info signal::imp received signal SIGTERM, starting shutdown
  16:28:36.248383Z info inpod::workloadmanager drain requested
  16:29:01.249405Z warn drain:proxy{wl=ambient/client-...} drain duration expired with pending connections, forcefully shutting down component="outbound"
  ```

  fortio's reconnects landed in the same second as that forced shutdown, in all three runs. New
  connections were served by the replacement ztunnel. **Existing connections lasted exactly as long
  as the drain window (25 s with the chart's 30 s `terminationGracePeriodSeconds`) and were then
  cut.** fortio retried on `EOF`. A gRPC stream or a database connection pool would see a
  disconnect on every ztunnel restart or upgrade.

- **Crash (`crictl stop -t 0` = SIGKILL):** the sidecar namespace had 0 errors every time. Both
  ambient namespaces failed together:

  | run | ambient errors | ambient-wp errors | error window |
  | --- | -------------- | ----------------- | ------------ |
  | 1   | 112            | 112               | ~1,080 ms    |
  | 2   | 20             | 24                | 161 / 204 ms |
  | 3   | 40             | 40                | 360 ms       |

  Every failed request failed at name resolution, for example
  `lookup server on 10.96.0.10:53: read udp ...: read: connection refused`. DNS for ambient pods was
  handled by ztunnel's DNS proxy in this install. While ztunnel was down, nothing was listening, so
  the pods could not even resolve the Service name. The blast radius is every ambient pod on the
  node, and it covers DNS as well as the data path. I did not kill a single sidecar for comparison.

### Control plane outage

I scaled istiod to 0, then scaled each server Deployment to 2 replicas:

| check                                    | sidecar                                                                                            | ambient / ambient-wp                                                                                     |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| existing traffic (200 requests)          | 200/200 OK                                                                                         | 200/200 OK                                                                                               |
| new pod created?                         | **no**: `failed calling webhook "namespace.sidecar-injector.istio.io" ... connection refused`      | **yes**, `1/1 Running`, Ready                                                                            |
| traffic to the new pod by IP             | n/a                                                                                                | **0/20**, all `i/o timeout`                                                                              |
| traffic via the Service                  | 100/100 (only the old pod exists)                                                                  | 100/100 (the client ztunnel's stale view only had the old endpoint)                                      |
| after istiod is back                     | second pod created within 30 s in one run; not within 60 s in the other                            | new pod reachable within 30 s                                                                            |

The server-node ztunnel explained the timeouts:

```text
warn access connection failed src.addr=10.244.1.15:39386 dst.addr=10.244.2.88:8080 direction="inbound"
  error="failed to fetch information about local workload: server.ambient (server-d87c87d86-7clt8)"
```

Sidecar mode fails closed at admission: you cannot create pods. Ambient admits the pod, and the pod
passes its kubelet readiness checks and becomes Ready, while ztunnel refuses its inbound mesh
traffic. In my test, meshed clients were protected by their own stale view of the endpoints.
**I did not test** a client outside the mesh going through kube-proxy, which would see both
endpoints. I would expect it to hit the unreachable pod, but that is a hypothesis, not a result.

## Analysis

**The cost model is different, not just smaller.** Sidecar cost grows with pods × mesh config:
about 28 MiB per pod at idle, plus about 0.2 MiB per extra Service, plus a 100m/128Mi reservation
per pod. Ambient L4 cost grows with nodes, at a few MiB per ztunnel and a 200m/512Mi reservation per
node, and was almost insensitive to mesh size. Ambient with L7 adds a waypoint per namespace (or per
service) whose cost grows with traffic and with that namespace's config only. On a dense node, the
reservation difference alone decided whether pods could be scheduled.

**The L4 data path is where ambient wins.** At a fixed rate ztunnel added about 28% of the
sidecar's p50 latency overhead at about 37% of its CPU, and per request it got cheaper as load increased. The win
disappeared when every request opened a new connection, and also when the waypoint was in the
path. In this lab the waypoint sat on the server node, and the sidecar was still faster at p50
(1.63 vs 1.90 ms).

**L7 features do not degrade gracefully without a waypoint.** Retries in a VirtualService were
ignored. An HTTP DENY failed open with a misleading status. `REGISTRY_ONLY` was not enforced, and
even with a waypoint, egress control only covered traffic addressed to a ServiceEntry VIP.
None of these produced an error at apply time. In sidecar mode, the same objects did what they
said. This is the biggest operational risk of migrating an existing sidecar mesh to ambient: your
YAML still applies, and some of it stops meaning anything.

**Upgrades move from the app's lifecycle to the node's.** Sidecar upgrades are free at control-plane
time and expensive later, because every pod has to restart and the proxy versions stay skewed until
it does. Ambient upgrades happen without touching apps, but each ztunnel upgrade closes every
connection on its node after 25 s. Each waypoint upgrade is a Deployment rollout, and with one
replica it dropped requests.

**Failure domains change shape.** A ztunnel crash took out data path and DNS for every ambient pod on
the node for 0.16 to 1.1 s. With istiod down, sidecar mode refused new pods, while ambient admitted
pods that looked healthy and were not.

## When to pick which

Pick **ambient (L4 only)** when:

- what you need is mTLS, workload identity and L4 authorization;
- pod density is high, or the mesh has many Services, so per-pod Envoy memory and requests hurt;
- you want proxy upgrades without rolling every workload;
- your clients survive a connection reset on every node-proxy upgrade;
- you can make sure nobody writes HTTP attributes into ztunnel-bound policies.

Pick **sidecar** when:

- most services need L7 traffic management or HTTP authorization anyway;
- you rely on `REGISTRY_ONLY` to lock down egress at the workload;
- you prefer failing closed at admission over admitting pods the data plane cannot serve;
- you want per-pod failure isolation and per-pod proxy tuning.

Pick **ambient with waypoints only where L7 is needed**. Give each waypoint 2+ replicas and a
PodDisruptionBudget (untested here, but the single-replica rollout dropped requests). Do not
expect it to beat sidecars on latency.

Both modes ran side by side in one mesh under a single istiod in this lab. I did not test traffic
between sidecar and ambient workloads, so check that path yourself before planning a gradual
migration on it.

## Caveats

- One VM with 4 vCPU shared by the load generator, three Kind nodes and Docker. Absolute numbers
  will not transfer. Ratios are more trustworthy than milliseconds, and the closed-loop throughput
  numbers measure CPU efficiency, not capacity.
- Both kube-proxy and Istio ran on the nftables backend because of kernel limits on this VM. The
  default iptables and ipset path was not measured.
- HTTP/1.1, tiny payloads, one client and one server per mode. I tested no HTTP/2, gRPC, large
  bodies or TLS origination.
- The waypoint was a single replica and landed on the server node for the benchmarks. Its
  placement was not controlled.
- The upgrade test ran once. The restart, crash and authorization tests ran three times each, and
  their counts vary a lot between runs.
- Not tested: revision-based or canary upgrades, the sidecar CNI mode, the `Sidecar` resource for
  scoping config, a dedicated `istio-egress` waypoint namespace, NetworkPolicy for egress, Gateway API `HTTPRoute` retries, multi-cluster, and
  traffic between sidecar and ambient workloads.

## Evidence appendix

Everything is under
[`docs/labs/istio-ambient-vs-sidecar/`](https://github.com/netf/blog/tree/main/docs/labs/istio-ambient-vs-sidecar).
The README there lists the run order and every environment workaround.

| claim                                     | script                         | raw evidence                                              |
| ----------------------------------------- | ------------------------------ | --------------------------------------------------------- |
| versions, nodes, Helm releases            | -                              | `results/versions.txt`, `results/install-1.30.5.log`      |
| upgrade under load                        | `03-upgrade-under-load.sh`     | `results/upgrade/` (timeline, fortio JSON, proxy-status)  |
| rollout under load                        | `04-restart-under-load.sh`     | `results/restart/run{1,2,3}/`                             |
| latency, CPU, memory                      | `bench.py`, `summarize.py`     | `results/bench/*.jsonl`, `results/bench/summary.md`       |
| mTLS on the wire, STRICT                  | `05-mtls.sh`                   | `results/mtls/`                                           |
| retries                                   | `06-l7-retries-authz.sh`       | `results/l7/retries.jsonl`                                |
| authz propagation, ztunnel HTTP-only DENY | `06b-...sh`, `06c-...sh`       | `results/l7/authz-*.txt`, `results/l7/ztunnel-rbac-source.txt` |
| outbound                                  | `07-outbound.sh`               | `results/outbound/outbound.txt`                           |
| fan-out and density memory                | `08-scale-memory.sh`           | `results/scale/`                                          |
| ztunnel graceful and crash                | `09-ztunnel-failure.sh`        | `results/ztunnel-failure/run{1,2,3}/`                     |
| istiod outage                             | `10-istiod-outage.sh`          | `results/istiod-outage/`                                  |

The cluster definition:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: mesh-lab
networking:
  kubeProxyMode: nftables
nodes:
  - role: control-plane
    image: kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
  - role: worker
    image: kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
    labels: { lab/role: client }
  - role: worker
    image: kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
    labels: { lab/role: server }
```

A single benchmark run, as `bench.py` issues it:

```bash
kubectl -n ambient exec deploy/client -c fortio -- \
  fortio load -qps 1000 -c 16 -t 60s -r 0.00001 -p 50,90,99,99.9 -json - http://server:8080/echo
docker exec mesh-lab-worker crictl stats -o json   # before and after, per container CPU ns
```

Trimmed output from the ztunnel HTTP-only DENY check (`06c-ztunnel-http-deny.sh`):

```text
ambient, HTTP-only DENY /debug, fresh pod (sa default): /debug -> HTTP/1.1 200, /echo -> HTTP/1.1 200
policy as pushed to ztunnel (istioctl ztunnel-config policies):
{"name":"deny-debug","namespace":"ambient","scope":"WorkloadSelector","action":"Deny","rules":[[[{}]]]}
ambient, L4 DENY principal sa/client: sa/client -> EOF, sa/default (fresh pod) -> HTTP/1.1 200
```

If you re-run this on real hardware and get different numbers, I would like to see them. That is
the point of publishing the scripts.
