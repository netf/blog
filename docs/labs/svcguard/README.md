# Lab: svcguard (Service and Endpoint traffic-hijack paths)

**Status: stopped at preflight. No attack has been run and no number has been measured.**
See [`environment.md`](environment.md): this VM's kernel lacks the iptables `statistic` match, so
the kube-proxy iptables arm can't run here. The options are listed there; the lab resumes once one
is chosen.

Attack material in this directory is for a throwaway Kind cluster only.

## What exists so far

| Path | What | State |
|---|---|---|
| `environment.md`, `results/preflight/` | preflight, kernel config, source check, blocker evidence, nftables check | done |
| `scripts/00-tools.sh`, `00b-start-dockerd.sh`, `01-preflight.sh`, `02b-host-iptables-fix.sh` | tool pins, dockerd without systemd, preflight, dual-iptables fix | used |
| `kind-{iptables,nftables,cilium}.yaml` | 1 control plane + 1 worker, dual-stack, `kindest/node:v1.37.2` (built locally from release binaries) | nftables and Cilium clusters came up |
| `scripts/cilium-values.yaml` | Cilium v1.20.4 KPR, native routing, L7 proxy off | Cilium came up healthy |
| `app/lab.py`, `app/Dockerfile` | identity-reporting TLS/HTTP server and victim client (canary card number, counts plaintext bytes an impostor receives) | tested locally in Docker: real cert verifies, impostor cert is rejected with verification on and receives 1,144 bytes per request with it off |
| `scripts/03-certs.sh` | lab CA, real payments cert, self-signed impostor cert | used |
| `manifests/tenants.yaml`, `gateway.yaml`, `metallb-pool.yaml`, `scripts/10-cluster.sh` | tenants A/B, NetworkPolicy, shared Envoy Gateway and Traefik routes, `edit` user and a labelled mis-scoped role | **not yet validated**: the first bring-up hit the blocker |

## Not built yet

The admission policies, RBAC reconciler, hijack detector, attack suite, false-positive chart run,
admission-latency benchmark and failure tests are not written. One design constraint already
fixed for the policies: ValidatingAdmissionPolicy has no lookups, so CEL can't check "this address
belongs to a pod in the same namespace". The plan is to deny pod, Service, node, loopback and
link-local ranges outright for any EndpointSlice or Endpoints not written by the controller service
accounts, and allow per-namespace approved CIDRs (the external-database case) from a param object
tenants can't edit. Legacy Endpoints must be checked too, because the EndpointSlice mirroring
controller writes the mirrored slice under its own identity.
