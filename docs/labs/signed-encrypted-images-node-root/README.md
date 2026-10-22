# Lab: signed and encrypted images vs root on the node

Reproduction kit for the post
[I signed and encrypted every image. Then I logged into the node as root](../../../src/content/blog/signed-encrypted-images-node-root.md).
Every number in the post comes from `results/`, produced by these scripts.

## Run it

```bash
./reproduce.sh            # blank Ubuntu 24.04 VM, ~25 min
DEFAULT_TTL=1 ./reproduce.sh   # also watch the stale window at Kyverno's default 60m TTL for 11 min
```

Read `environment.md` first: it records the preflight and the three workarounds this VM needed.
No script opens `/dev/kvm` or starts a VM.

## What it builds

- Kind cluster `supply` (1 control plane, 2 workers, Kubernetes v1.37.0, containerd 2.3.4) and
  `registry:2.8.3` at `kind-registry:5000`, reachable under that name from host, nodes and pods.
- `app/`: a static Go binary in `scratch` plus an 8 MiB `model.bin` starting with
  `PROPRIETARY-MODEL-MARKER-7f3a9c`. Images: `app:v1` (signed), `app:evil`, `app:evil2` (never
  signed), `app-plain:v1` and `app-enc:v1` (same platform image, plain and ocicrypt-encrypted).
- Kyverno v1.19.1 with `manifests/policy-verify.yaml` on namespace `prod`.
- ocicrypt decoder on both workers, private key on `supply-worker` only.

## Scripts and results

| Script | What | Results |
|---|---|---|
| `00-tools.sh`, `00b-start-dockerd.sh`, `01-preflight.sh` | pinned tools, dockerd, read-only preflight | `results/preflight/`, `results/versions.txt` |
| `03-cluster.sh` | Kind + registry + node registry config + iptables fix | `results/cluster/` |
| `09-images.sh`, `10-sign.sh` | build, cosign sign, SBOM + SLSA attestations | `results/sign/` |
| `11-kyverno.sh`, `11b-format-compat.sh` | install; which `verifyImages` settings accept cosign v3 bundles | `results/format-compat/` |
| `12-attacks.sh` | unsigned, transplanted signature, tag repoint | `results/admission/attacks.tsv` |
| `13-repoint-cache.sh default\|ttl2m\|off` | stale verify-cache window after a repoint | `results/repoint-cache/<mode>/` |
| `14-registry-down.sh`, `14b-failure-modes.sh`, `14c-kyverno-crash.sh`, `14d-two-replicas.sh` | registry hung, Audit, Kyverno down (graceful, SIGKILL, 2 replicas) | `results/registry-down/`, `results/failure-modes/` |
| `15-latency.sh` | admission latency, 30 samples per case | `results/latency/summary.txt` |
| `20-encrypt.sh`, `21-stolen-copy.sh` | encrypt; attacker with registry read access | `results/encrypt/`, `results/stolen-copy/` |
| `22-node-keys.sh`, `23-run-encrypted.sh` | node-model decryption; keyed vs keyless; pull/start timing | `results/node-keys/`, `results/run-encrypted/` |
| `30-node-root.sh` | twelve timed steps as root on `supply-worker` | `results/node-root/steps.tsv` and one file per step |

Directories ending in `-exploratory`, `-dropped-by-chart`, `-stopstart` and
`results-audit-not-applied.tsv` are kept on purpose: they are the runs where my setup was wrong.

`results/repoint-cache/default/` is from the first VM (2026-10-15), which was recycled after the
t=483 s poll; everything else is from the second run (2026-10-22) unless noted.

## Cleanup

```bash
kind delete cluster --name supply && docker rm -f kind-registry
```
