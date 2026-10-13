---
title: 'Istio ambient is cheaper than sidecars. It also quietly ignored my YAML'
description: "I ran Istio's ambient mode and classic sidecars side by side on one cluster. Ambient really did cut latency and CPU. It also silently skipped my retries, a deny policy and my egress lockdown."
pubDate: 2026-10-12
tags: ['kubernetes', 'istio', 'service-mesh', 'benchmarks']
featured: true
---

My idea of a good time: one Kubernetes cluster, Istio's two data planes running side by side, and a
list of ways to break them both.

If you run Istio the classic way, every pod carries its own proxy, the sidecar. That proxy is the
reason the mesh works at all: it terminates mTLS, retries failed calls, and enforces authorization
before traffic ever reaches your app.

**It's also a tax on every replica.** Each pod gets an extra container, extra CPU and memory
reservations, and an init container that needs `NET_ADMIN`. And when you upgrade Istio, none of
those proxies move until you roll the application itself. If you've ever had to restart a few
hundred Deployments just to pick up a mesh patch, you know the feeling.

**Ambient mode is Istio's answer to that tax.** Instead of a proxy in every pod, one node-level
proxy (ztunnel) handles encryption and identity for everything on the node. You add a shared Envoy,
called a waypoint, only for the namespaces that actually need layer 7. Fewer proxies, less reserved
capacity, and proxy upgrades that don't restart your apps.

That's the pitch, and it's a good one. I wanted to know how much of it survives contact with a
running cluster, so I wrote down three questions. I didn't trust a vendor benchmark to answer any of
them:

1. **How much do you actually save?** Latency, CPU and memory, measured against an identical
   workload with no mesh at all, so the cost of the mesh is visible on its own.
2. **What do you give up?** mTLS, retries, authorization, egress control. The features people
   adopted sidecars for in the first place.
3. **What fails differently?** Upgrades, a dead proxy, a dead control plane. The cost model is
   irrelevant if the failure mode is worse.

To make it a fair fight, both modes ran at the same time, on the same cluster, under the same
istiod, with the same application: a Kind cluster, four namespaces, one client/server pair each (no
mesh, sidecar, ambient, and ambient with a waypoint). Clients and servers were pinned to different
nodes, so every request crossed the network.

**One rule for this write-up: if I didn't observe it, it isn't here, and if I couldn't test
something, I say so.** The scripts and raw output are in
[`docs/labs/istio-ambient-vs-sidecar/`](https://github.com/netf/blog/tree/main/docs/labs/istio-ambient-vs-sidecar),
so you can check my work.

**Most of what I found was the good news you'd hope for.** Ambient really is cheaper, more or less
the way the pitch suggests.

Then I applied a three-line `AuthorizationPolicy` denying `GET /debug`. The cluster warned me it
would enforce that policy *more restrictively* than I'd asked. Instead, `/debug` returned `200 OK`.
So did everything else, for ninety polls in a row.

**The YAML had stopped meaning what it said, and nothing had errored.** That turned out to be the
real story of this lab, and it wasn't a one-off: the same thing happened with retries and with
egress.

## The short version

- **Ambient at L4 is genuinely cheap.** At 1,000 req/s it added 0.39 ms to median latency against
  1.40 ms for sidecars, and used about a third of the CPU. On a CPU-bound box it pushed 3.6x the
  sidecar's throughput.
- **Add a waypoint and most of that advantage disappears.** With L7 in the path, ambient was
  slightly *slower* than sidecars at the median (1.90 vs 1.63 ms), though still cheaper on CPU.
- **Sidecar memory scales with your mesh, not your app.** Adding 200 Services that a workload never
  calls grew every sidecar from about 28 to 69 MiB. ztunnel grew by under a megabyte.
- **Some of your YAML stops working without telling you.** Without a waypoint, VirtualService
  retries were ignored, an HTTP DENY failed open, and `REGISTRY_ONLY` blocked nothing.
- **Upgrades get easier and also sharper.** Ambient proxies upgrade without restarting your apps,
  but every ztunnel restart cuts every connection on its node after 25 seconds.
- **The blast radius moves to the node.** Killing one ztunnel broke traffic, DNS included, for every
  ambient pod on that node.

In this article, we cover:

1. **The lab.** What ran where, and why the absolute numbers come with a caveat.
2. **The bill.** Latency, CPU and memory, measured against no mesh at all.
3. **Is it actually encrypted?** Checked on the wire with tcpdump.
4. **The YAML that quietly stopped working.** Retries, deny policies and egress.
5. **Bad days.** An upgrade under load, a dead ztunnel and a missing istiod.
6. **So which one would I pick?** Plus what I'd check before migrating.
7. **What this lab can't tell you.**

## 1. The lab: one cluster, four namespaces

One istiod, installed with Helm using `profile=ambient`, served all four namespaces, so the only
thing that differed between them was the data plane. Kubernetes was 1.36.4.

| namespace    | data plane                                    |
| ------------ | --------------------------------------------- |
| `baseline`   | no mesh, as the control group                 |
| `sidecar`    | classic Envoy sidecar in every pod            |
| `ambient`    | ztunnel on each node (L4 only)                |
| `ambient-wp` | ambient plus a namespace waypoint (Envoy, L7) |

The cluster actually started on Istio 1.30.5, so I could do a real in-place upgrade under load
later. Every measurement below is from 1.31.1 unless a section says otherwise. Kubernetes 1.36 was
the newest version that
[both Istio releases support](https://istio.io/latest/docs/releases/supported-releases/).

**You can see the difference before measuring anything.** A sidecar pod gets two extra containers:
an `istio-init` that runs as root with `NET_ADMIN` and `NET_RAW`, and an `istio-proxy` that
requests 100m CPU and 128Mi. An ambient pod gets nothing except an annotation. Its traffic is
handled by a per-node ztunnel that requests 200m and 512Mi.

Even the responses look different:

- **Sidecar** responses come back with `server: envoy` and an `X-Forwarded-Client-Cert` header
  containing both workload identities.
- **Ambient** responses come back untouched.
- **Waypoint** responses say `server: istio-envoy`.

**A word on honesty: Kind fought me before Istio did.** My lab VM's kernel had no ipset support and
no iptables `statistic` match, so both kube-proxy and Istio run on their **nftables** backends here,
which is not the default. The full list of workarounds is in
[Appendix B](#appendix-b-environment-workarounds).

This matters for how far you should trust the absolute numbers. Everything ran on one 4 vCPU VM, so
compare the modes with each other, and treat the milliseconds as specific to this machine.

## 2. The bill: what the mesh actually costs

### Latency: ambient L4 is close to free, waypoints are not

The main test was steady traffic: 1,000 requests per second over 16 keep-alive connections for 60
seconds. I ran three rounds, rotating the order of the modes each round. None of the 12 runs
returned a single non-200 response.

Here are the medians, in milliseconds:

| mode               | p50  | p90  | p99  | p99.9 |
| ------------------ | ---- | ---- | ---- | ----- |
| no mesh            | 0.23 | 0.34 | 0.56 | 1.63  |
| sidecar            | 1.63 | 2.00 | 2.59 | 5.73  |
| ambient            | 0.62 | 0.89 | 1.38 | 2.34  |
| ambient + waypoint | 1.90 | 2.41 | 2.92 | 5.07  |

**Subtract the baseline, and the mesh costs +0.39 ms at the median for ambient, +1.40 ms for
sidecars, and +1.67 ms for ambient with a waypoint.**

That last number surprised me. I'd half-assumed that a single waypoint would beat two sidecars,
because it's one Envoy hop instead of two. It didn't. The traffic still crosses two ztunnels as
well, and in this lab the waypoint happened to sit on the server's node.

Two more tests sharpened the picture:

- **A new TCP connection for every request** (200 req/s) narrowed the gap between ambient and
  sidecar from 1.01 ms to 0.46 ms at the median. Neither proxy does a fresh TLS handshake per app
  connection, because both pool their node-to-node mTLS connections. So most of ambient's lead comes
  from handling requests on long-lived connections, not from opening them.
- **Flat out** (no rate limit, 16 connections), the box saturated at about 41,000 req/s with ambient,
  12,900 with a waypoint, and 11,500 with sidecars. This measures how much CPU each request costs,
  not how much your cluster can handle.

### CPU: you pay roughly a third

At the same 1,000 req/s, this is what the proxies themselves consumed, measured from container CPU
counters immediately before and after each run:

| mode               | proxy CPU (cores) | where it went                    |
| ------------------ | ----------------- | -------------------------------- |
| sidecar            | 0.206             | 0.106 client side + 0.100 server side |
| ambient            | 0.077             | two ztunnels, about 0.04 each    |
| ambient + waypoint | 0.156             | waypoint 0.088 + ztunnels 0.067  |

**ztunnel even got *cheaper* per request as load went up.** It used 77 millicores per 1,000 req/s
at the steady rate, and 40 when flat out. The sidecars barely moved (206 down to 186).

The one place the advantage vanished was the new-connection-per-request test. There, sidecar and
ztunnel cost almost exactly the same: 557 and 566 millicores per 1,000 req/s.

### Memory: the cost that grows when nobody is looking

**This is the result I'd show a finance team.**

A fresh sidecar sat at about 28 MiB, a ztunnel at about 4 MiB, and a waypoint at about 25 MiB. Then
I added 200 Services to an unrelated namespace: Services that none of my test workloads would ever
call.

| proxy                   | before   | after 200 Services | what it learned           |
| ----------------------- | -------- | ------------------ | ------------------------- |
| each sidecar            | ~28 MiB  | **~69 MiB**        | 22 → 422 Envoy clusters   |
| each ztunnel (per node) | ~4.2 MiB | ~5.0 MiB           | 8 → 208 services          |
| waypoint                | 25.3 MiB | 25.9 MiB           | unchanged (own namespace) |

Read the first row again. **Every sidecar more than doubled its memory for Services it will never
talk to.** By default, every sidecar receives configuration for every Service in the mesh. Here,
that meant about 40 MiB extra for each pod, for nothing. In a cluster with thousands of pods, that's
real money.

You can scope it down with the `Sidecar` resource, but I didn't test that, so I can't tell you how
much it would win back.

Envoy didn't give the memory back, either. After I deleted the 200 Services, the sidecars stayed
high, at 90 and 66 MiB, until their pods restarted. The waypoint did the same: it climbed to 93 MiB
during the flat-out benchmark and stayed there.

Pod density told the same story from the other side. Scaling a server to 10 replicas added about
257 MiB of sidecars. Doing the same in ambient grew that node's ztunnel by 1.3 MiB.

**There's a quieter cost too: resource requests.** With default settings, each sidecar pod reserves
an extra 100m CPU and 128Mi. When I first scaled both namespaces to 10 replicas on one 4-CPU node,
the node ran out of requestable CPU, and two of the *ambient* pods sat in `Pending` with
`Insufficient cpu`. The sidecars had already called dibs on the room.

A ztunnel's reservation equals four sidecars for memory and two for CPU, so it pays for itself
quickly on a busy node.

## 3. Is it actually encrypted? (Yes.)

I didn't want to take a dashboard's word for it, so I checked on the wire: tcpdump on the server's
node, while each client sent requests carrying the header `X-Lab-Marker: PLAINTEXT-CANARY-42`.

| mode               | canary visible? | port  | TLS handshake                           |
| ------------------ | --------------- | ----- | --------------------------------------- |
| no mesh            | yes, 5 packets  | 8080  | none                                    |
| sidecar            | no              | 8080  | TLS 1.3, Istio's own ALPN (`istio-http/1.1`) |
| ambient            | no              | 15008 | TLS 1.3, ALPN `h2` (HBONE)              |
| ambient + waypoint | no              | 15008 | TLS 1.3, ALPN `h2` (HBONE)              |

**The canary only showed up where it should: with no mesh at all.** Sidecars keep classic Istio
mTLS on the app's own port. Ambient moves everything onto a single HBONE port, 15008.

Identity survives in both modes. The sidecar passed the caller's SPIFFE ID in a header, and ztunnel
logged both sides of every connection:

```text
info access connection complete src.identity="spiffe://cluster.local/ns/ambient/sa/client"
  dst.addr=10.244.2.24:15008 dst.hbone_addr=10.244.2.24:8080
  dst.identity="spiffe://cluster.local/ns/ambient/sa/server" direction="inbound" duration="2ms"
```

With `PeerAuthentication` set to `STRICT`, all three meshed servers rejected a plaintext client from
outside the mesh with a connection reset. **On the security fundamentals, the two modes are
equivalent.**

## 4. The YAML that quietly stopped working

**If you read one section before migrating, make it this one.** Everything below applied cleanly
and raised no errors. That's the problem.

### Retries that don't retry

I made the server fail half its requests with `503`, then counted what the client saw over 2,000
requests:

| setup                       | sidecar      | ambient       | ambient + waypoint |
| --------------------------- | ------------ | ------------- | ------------------ |
| no VirtualService           | 49.7% failed | 46.9% failed  | 50.0% failed       |
| VirtualService, 5 retries   | **1.55%**    | **50.5%**     | **1.7%**           |

**My first surprise was the top row.** I'd assumed Istio retries 503s by default. It doesn't: the
default policy retries on connection failures, but its list of retriable status codes is empty.

**The second surprise was the ambient column.** Sidecar and waypoint matched the math almost
exactly: with six attempts, 0.5<sup>6</sup> ≈ 1.56% of requests should still fail. Without a
waypoint, the VirtualService applied cleanly, produced no warning, and did absolutely nothing. Half
the requests kept failing.

Even where retries worked, they weren't free: p99 jumped from about 3 ms to about 360 ms, which I
attribute to Envoy's backoff between attempts. Retries hide errors, and the errors show up in your
tail latency instead.

### The deny policy that denies nothing

Back to the story from the start. The policy was `action: DENY` with one rule matching path
`/debug`. I applied it in each mode and polled once a second:

| mode               | `/debug` started returning 403 after | other paths   |
| ------------------ | ------------------------------------ | ------------- |
| sidecar            | 1.2 s, 3.4 s, 2.3 s                  | still 200     |
| ambient + waypoint | 1.2 s, 1.2 s, 1.2 s                  | still 200     |
| ambient            | **never** (3 rounds × 90 polls)      | still 200     |

(Before those timed rounds, one ad-hoc attempt took the sidecar 15 to 20 seconds to start denying.
I couldn't reproduce it, but it's a good reminder to verify policy changes rather than assume them.)

Here's the status istiod wrote on the ambient policy:

```text
ZtunnelAccepted=True reason=UnsupportedValue: ztunnel does not support HTTP attributes (found: paths).
In ambient mode you must use a waypoint proxy to enforce HTTP rules. DENY policy with HTTP attributes
is enforced without the HTTP rules. This will be more restrictive than requested.
```

`kubectl apply` added its own warning: `will deny all traffic to TCP ports under its scope`. Both
messages promise that everything will be denied. **In reality, nothing was.** Not even requests
from a brand-new pod with no pooled connections.

So I went digging. This is the policy that actually reached ztunnel:

```json
{"name":"deny-debug","namespace":"ambient","action":"Deny","rules":[[[{}]]]}
```

That's a rule whose only condition is empty. In ztunnel 1.31.1's
[`src/rbac.rs`](https://github.com/istio/ztunnel/blob/1.31.1/src/rbac.rs), the matching code skips
empty conditions (`if mg.is_empty() { continue; }`). A rule made only of an empty condition
therefore never matches, so the DENY never fires. A policy that promises to deny everything ends up
denying nothing.

To rule out a general enforcement problem, I applied an L4 DENY on the client's identity, and
ztunnel enforced it immediately. **Only the HTTP rule fails, and it fails *open*: the opposite of
what the status says.**

My take: if you run ambient without waypoints, never put HTTP attributes in policies that ztunnel
enforces. Better still, make `UnsupportedValue` on `ZtunnelAccepted` fail your CI.

### Egress lockdown that isn't

I put a plain HTTP server outside the cluster and had each client call it. Then I switched the mesh
to `outboundTrafficPolicy: REGISTRY_ONLY`, which is meant to block anything not in Istio's service
registry:

| policy                         | no mesh | sidecar     | ambient | ambient + waypoint |
| ------------------------------ | ------- | ----------- | ------- | ------------------ |
| `ALLOW_ANY` (default)          | 200     | 200         | 200     | 200                |
| `REGISTRY_ONLY`                | 200     | **502**     | **200** | **200**            |
| `REGISTRY_ONLY` + ServiceEntry | 200     | 200         | 200     | 200                |

**Only the sidecar enforced it.** Ambient pods walked straight out, with or without a waypoint.

Next, I tried the documented way to send egress through a waypoint. Istio's
[ambient egress docs](https://istio.io/latest/docs/ambient/usage/egress-gateway/) say a ServiceEntry
in a waypoint-enrolled namespace is routed through the waypoint automatically. My first attempt
didn't route through it: there were no Envoy headers, and ztunnel logged a direct connection. That
held even though the ServiceEntry reported `WaypointBound=True`.

The difference turned out to be one field. I'd set `addresses:` to the external server's real IP.
When I left `addresses` out, Istio assigned a virtual IP, and calls by hostname went through the
waypoint as documented.

**The catch: a pod calling the external IP directly bypassed the waypoint either way, and
`REGISTRY_ONLY` didn't stop it.** In ambient, the waypoint only governs egress that is addressed to
the ServiceEntry. I didn't test NetworkPolicy or a dedicated egress namespace as ways to close that
gap.

## 5. Bad days: upgrades, crashes and a missing control plane

Cheap is nice. What I really wanted to know is what happens when things go wrong.

### Upgrading under load

I upgraded the running mesh from 1.30.5 to 1.31.1 with `helm upgrade` while each meshed namespace
handled 100 req/s for five minutes. That's 30,000 requests per namespace:

| mode               | failed | what happened                                                        |
| ------------------ | ------ | -------------------------------------------------------------------- |
| sidecar            | 0      | Nothing at all, because the sidecars were still running 1.30.5 afterwards. |
| ambient            | 0      | The ztunnel upgrade closed all 4 connections; the client reconnected.      |
| ambient + waypoint | **16** | The istiod upgrade rolled the waypoint, and 4 requests hung for 3 s.       |

Each row tells a different story:

- **Sidecar: perfect, but only because nothing was upgraded.** `istioctl proxy-status` showed the
  sidecars still on 1.30.5, waiting for someone to restart every pod.
- **Ambient: really upgraded, without touching a single app.** The only cost was a reconnect.
- **Ambient + waypoint: the casualty.** The waypoint is a Deployment that istiod manages, so
  upgrading istiod silently rolled it, and with the default single replica, requests dropped.

My take: I'd run waypoints with at least two replicas and a PodDisruptionBudget. I didn't test that
setup, though.

What about the sidecar restarts that the upgrade postponed? I rolled the server Deployment under
load three times in each mode. Every mode lost a handful of requests out of 6,000, including the
no-mesh baseline, because my test server has one replica and no graceful shutdown. The counts were
too noisy to rank.

**The *shape* was consistent, though.** The sidecar always failed fast, with a 503 in under 75 ms.
Every other mode hit the client's 3-second timeout in at least one run.

### When ztunnel dies

All three meshed clients shared one node. I removed that node's ztunnel two ways, three times each.

**Gracefully (`kubectl delete pod`), nothing failed.** But every ambient connection was closed
exactly 25 seconds later, and the old ztunnel's log says why:

```text
16:28:36.247 info received signal SIGTERM, starting shutdown
16:29:01.249 warn drain duration expired with pending connections, forcefully shutting down
```

New connections went to the replacement ztunnel immediately. Existing ones got 25 seconds, which
comes from the chart's 30-second termination grace period, and were then cut. fortio shrugged and
reconnected. **Your gRPC streams and database pools won't be so relaxed: they'll see a disconnect on
every ztunnel upgrade.**

**Crashed (SIGKILL), the sidecar namespace didn't notice, and both ambient namespaces failed
together:** 112, 20 to 24, and 40 failed requests across the three runs, over windows of 0.16 to 1.1
seconds. And every single failure was DNS. (It's always DNS.)

```text
lookup server on 10.96.0.10:53: read udp ...: read: connection refused
```

In this install, ztunnel also answers DNS for ambient pods. When it dies, those pods can't even
resolve a Service name until it comes back. **One ztunnel is a shared dependency for every ambient
pod on its node.** I didn't kill an individual sidecar for comparison.

### When istiod disappears

I scaled istiod to zero and kept going:

- **Existing traffic** carried on in all modes (200/200 requests each).
- **New sidecar pods** couldn't be created at all, because the injection webhook failed:
  `failed calling webhook "namespace.sidecar-injector.istio.io" ... connection refused`.
- **New ambient pods** started, passed readiness, and showed `1/1 Running`, yet couldn't receive
  traffic. Direct requests timed out, and the node's ztunnel explained why:

```text
warn access connection failed dst.addr=10.244.2.88:8080 direction="inbound"
  error="failed to fetch information about local workload: server.ambient (server-d87c87d86-7clt8)"
```

When istiod came back, the new ambient pods became reachable within 30 seconds.

**My take: the sidecar behavior is easier to live with.** A deploy that fails loudly beats a pod
that says it's healthy and quietly drops traffic.

Requests through the Service were fine in my test, because the meshed clients still had the old
endpoint list. I didn't test a client outside the mesh, which would get the full endpoint list from
kube-proxy. I suspect it would hit the broken pod, but that's a hypothesis.

## 6. So which one would I pick?

**The cost models are fundamentally different:**

- **Sidecar** cost grows with **pods × mesh size**.
- **Ambient L4** cost grows with **nodes**, and barely notices mesh size.
- **Waypoint** cost grows with the traffic and config of the namespace it serves.

That alone answers the question for a lot of clusters. Here's how I'd decide:

**I'd pick ambient (L4 only)** when what I need is mTLS, workload identity and L4 policy across a
large, dense, or fast-growing mesh. I'd also want my apps to tolerate a reconnect on every node
upgrade, and policies to stay strictly L4, enforced by a CI check.

**I'd stay on sidecars** when most services genuinely need L7 routing or HTTP authorization, when
I rely on `REGISTRY_ONLY` for egress control, or when I'd rather fail closed than admit pods the
data plane can't serve.

**I'd add waypoints only where L7 is actually needed**, run them with at least two replicas, and
not expect them to beat sidecars on latency.

If you're migrating an existing sidecar mesh, here's what I'd do first, based on what bit me:

1. Grep your policies for HTTP attributes (`paths`, `methods`, `hosts`, `headers`) and check every
   one has a waypoint in front of it.
2. List every VirtualService and decide which ones need a waypoint. Without one, they do nothing.
3. If you use `REGISTRY_ONLY`, plan a replacement before you move a single namespace.
4. Find your long-lived connections (gRPC streams, DB pools, message brokers) and confirm they
   reconnect cleanly.
5. Alert on `ZtunnelAccepted` conditions that aren't clean.

Both modes ran happily side by side under one istiod in this lab, so a gradual migration is at
least plausible. I didn't test traffic *between* sidecar and ambient workloads, though, so verify
that path yourself.

## 7. What this lab can't tell you

- **It's one small VM.** Four vCPUs were shared by the load generator, three Kind nodes and Docker.
  Trust the ratios more than the milliseconds.
- **It's not the default network path.** Kernel limits forced nftables for both kube-proxy and
  Istio, so the default iptables and ipset path is unmeasured.
- **The traffic is simple.** HTTP/1.1 with tiny payloads: no HTTP/2, gRPC, large bodies, or TLS
  origination.
- **The waypoint setup is minimal.** It was a single replica, and its placement wasn't controlled.
- **Sample sizes are small.** The upgrade ran once. The restart, crash and policy tests ran three
  times each, and their counts vary a lot.
- **Plenty is untested:** revision-based upgrades, the sidecar CNI mode, `Sidecar` scoping,
  dedicated egress namespaces, NetworkPolicy for egress, Gateway API retries, multi-cluster, and
  traffic between sidecar and ambient workloads.

**If you run this on real hardware and get different numbers, I'd genuinely like to see them.**
That's why the scripts are public. I'd rather be corrected than quoted.

---

## Appendix A: Methodology and full tables

**Load.** fortio 1.76.0 runs inside the client pod (`kubectl exec deploy/client -- fortio load`)
against `http://server:8080/echo`, using HTTP/1.1 with 10 µs histogram resolution. Each run is
preceded by a 5-second warm-up that is discarded. I ran three rounds per scenario, rotating the
order of the modes each round.

**CPU.** I took cumulative `usageCoreNanoSeconds` from `crictl stats` on both workers immediately
before and after each run, and divided by fortio's actual duration. containerd reads the cgroup when
asked, whereas the kubelet summary API is cached. Memory is the container working set from the same
API.

**Steady rate, 1,000 req/s, 16 connections, 60 s** (ms, median with min-max across 3 rounds):

| mode       | p50              | p90              | p99              | p99.9            |
| ---------- | ---------------- | ---------------- | ---------------- | ---------------- |
| baseline   | 0.23 (0.22-0.23) | 0.34 (0.34-0.35) | 0.56 (0.53-0.56) | 1.63 (1.35-3.18) |
| sidecar    | 1.63 (1.52-1.69) | 2.00 (1.89-2.32) | 2.59 (2.48-3.44) | 5.73 (5.17-7.05) |
| ambient    | 0.62 (0.61-0.64) | 0.89 (0.87-0.91) | 1.38 (1.30-1.39) | 2.34 (1.89-3.29) |
| ambient-wp | 1.90 (1.86-1.92) | 2.41 (2.38-2.43) | 2.92 (2.91-2.99) | 5.07 (4.35-5.65) |

**New connection per request, 200 req/s, 30 s** (ms, medians):

| mode       | p50  | p90  | p99  | p99.9 |
| ---------- | ---- | ---- | ---- | ----- |
| baseline   | 0.82 | 1.05 | 1.58 | 7.50  |
| sidecar    | 1.80 | 2.35 | 2.93 | 5.50  |
| ambient    | 1.34 | 1.78 | 2.44 | 4.43  |
| ambient-wp | 2.38 | 2.96 | 3.71 | 6.00  |

The baseline p99.9 ranged from 2.50 to 7.75 ms between rounds, so ignore that column here.

**Closed loop, 16 connections, 30 s:**

| mode       | req/s (min-max)            | p50 ms | p99 ms |
| ---------- | -------------------------- | ------ | ------ |
| baseline   | 103,210 (87,228-108,184)   | 0.11   | 0.92   |
| sidecar    | 11,529 (10,086-11,695)     | 1.29   | 3.45   |
| ambient    | 40,962 (34,054-41,505)     | 0.35   | 1.22   |
| ambient-wp | 12,932 (11,753-13,909)     | 1.15   | 2.82   |

**Data-plane CPU, millicores per 1,000 req/s:**

| mode       | steady | closed loop | new conn per request |
| ---------- | ------ | ----------- | -------------------- |
| sidecar    | 206    | 186         | 557                  |
| ambient    | 77     | 40          | 566                  |
| ambient-wp | 156    | 121         | 651                  |

Both worker nodes' total CPU at the steady rate: 0.142 cores for baseline, 0.337 for sidecar, 0.209
for ambient, and 0.284 for ambient-wp.

**Upgrade timeline** (ambient-wp's resets landed at 14:45:50.99, and the ztunnel closes at
14:47:18-19):

```text
14:45:21.515 load started (300s, 100 qps, 4 conns) in sidecar ambient ambient-wp
14:45:43.627 helm upgrade istiod
14:45:46.495 istiod done
14:46:06.499 helm upgrade istio-cni
14:46:30.892 istio-cni done
14:46:50.897 helm upgrade ztunnel
14:47:21.173 ztunnel done
```

**Server rollout under load** (6,000 requests per run):

| run | baseline              | sidecar            | ambient               | ambient-wp                 |
| --- | --------------------- | ------------------ | --------------------- | -------------------------- |
| 1   | 4 err, max 8 ms       | 9 × 503, 75 ms     | 12 err, 3,001 ms      | 12 × 503, 13 ms            |
| 2   | 8 err, max 3 ms       | 8 × 503, 69 ms     | 16 err, 3,002 ms      | 4 err + 11 × 503, 3,003 ms |
| 3   | 20 err, 3,001 ms      | 6 × 503, 68 ms     | 8 err, 18 ms          | 4 err + 8 × 503, 3,002 ms  |

The baseline errors were `connection refused`, plus timeouts in run 3. The ambient errors were
`connection reset by peer` or `i/o timeout`, never `connection refused`.

## Appendix B: Environment workarounds

These are quirks of my lab VM, not of Istio, but each one changed the configuration:

1. **The Kind nodes had no internet egress.** I pulled images on the host and side-loaded them.
   `kind load docker-image` broke on multi-arch images, so I used
   `docker save --platform linux/amd64` with `kind load image-archive` instead.
2. **`registry.istio.io` was unreachable**, so I used `docker.io/istio`. Note that the ztunnel chart
   reads the top-level `hub` value, not `global.hub`.
3. **Two iptables backends were active.** A legacy `FORWARD DROP` silently dropped node-to-node
   traffic. The first symptom was `kubectl logs` timing out.
4. **The kernel had no iptables `statistic` match**, so kube-proxy couldn't program Services with
   more than one endpoint (CoreDNS was the first casualty). Fixed with `kubeProxyMode: nftables`.
5. **The kernel had no ipset**, so the ambient CNI agent crashed with
   `error initializing host addressSet manager`. Fixed with `global.nativeNftables=true`, which I
   set on istiod too so both data planes share the same backend.
6. **The 1.31.1 Helm charts weren't published yet**, so I installed both versions from the release
   tarballs.

The install itself, trimmed:

```bash
HUB=(--set global.hub=docker.io/istio --set hub=docker.io/istio --set global.variant=distroless --set variant=distroless)
NFT=(--set global.nativeNftables=true)
helm upgrade --install istio-base "$CHARTS/base" -n istio-system --create-namespace "${HUB[@]}" --wait
helm upgrade --install istiod "$CHARTS/istio-control/istio-discovery" -n istio-system --set profile=ambient "${HUB[@]}" "${NFT[@]}" --wait
helm upgrade --install istio-cni "$CHARTS/istio-cni" -n istio-system --set profile=ambient "${HUB[@]}" "${NFT[@]}" --wait
helm upgrade --install ztunnel "$CHARTS/ztunnel" -n istio-system "${HUB[@]}" --wait
istioctl waypoint apply -n ambient-wp --enroll-namespace --wait
```

## Appendix C: Versions and evidence

| component      | version                                                    |
| -------------- | ---------------------------------------------------------- |
| host           | Ubuntu 24.04.5, kernel 6.12.94+, 4 vCPU, ~5 GB usable RAM  |
| Docker / Kind  | 29.9.0 / v0.33.0                                           |
| Kubernetes     | v1.36.4 (`kindest/node`, pinned by digest), kindnet        |
| Istio          | 1.30.5 → 1.31.1, Helm, `profile=ambient`                   |
| Gateway API    | v1.5.1                                                     |
| load generator | fortio 1.76.0                                              |

Every claim maps to a script and its raw output under
[`docs/labs/istio-ambient-vs-sidecar/`](https://github.com/netf/blog/tree/main/docs/labs/istio-ambient-vs-sidecar),
whose README gives the full run order:

| claim                         | script                        | raw evidence                         |
| ----------------------------- | ----------------------------- | ------------------------------------ |
| latency, CPU, memory          | `bench.py`, `summarize.py`    | `results/bench/`                     |
| upgrade under load            | `03-upgrade-under-load.sh`    | `results/upgrade/`                   |
| rollout under load            | `04-restart-under-load.sh`    | `results/restart/`                   |
| mTLS on the wire              | `05-mtls.sh`                  | `results/mtls/`                      |
| retries                       | `06-l7-retries-authz.sh`      | `results/l7/retries.jsonl`           |
| deny policies                 | `06b-…`, `06c-…`              | `results/l7/`                        |
| egress                        | `07-outbound.sh`              | `results/outbound/`                  |
| memory scaling                | `08-scale-memory.sh`          | `results/scale/`                     |
| ztunnel graceful and crash    | `09-ztunnel-failure.sh`       | `results/ztunnel-failure/`           |
| istiod outage                 | `10-istiod-outage.sh`         | `results/istiod-outage/`             |
