# Lab: sakeyroll (service-account signing key rotation and an external signer)

**Status: stopped at preflight. Nothing has been built or measured, and no post has been written.**
See [`environment.md`](environment.md). Two things need a decision before the first measurement:

1. This VM's kernel lacks the iptables `statistic` match, so kube-proxy's iptables mode can't
   route to the three API servers behind the `kubernetes` Service (5 of 5 pod calls timed out).
   nftables mode works. Proposed: run both Kind clusters in nftables mode and say so in the post.
2. Nodes share one wall clock, so real clock skew can't be produced. Proposed: simulate skew at
   the verifier and say so.

## What exists so far

| Path | What | State |
|---|---|---|
| `environment.md`, `results/preflight/` | preflight facts, kernel config, source and API check, blocker evidence, nftables and RAM check, PEM-bundle check | done |
| `scripts/00-tools.sh`, `00b-start-dockerd.sh`, `01-preflight.sh`, `02b-host-iptables-fix.sh` | tool pins, dockerd without systemd, preflight, dual-iptables fix | used |
| `kind-preflight-3cp.yaml` | 3 control planes + 1 worker, default kube-proxy mode | reproduced the blocker |
| `kind-preflight-nft-a.yaml`, `kind-preflight-nft-b.yaml` | the two lab clusters in nftables mode | both came up and ran together |

## Facts from preflight that shape the build

- v1.37.2's external signer is `v1.ExternalJWTSigner` (`Sign`, `FetchKeys`, `Metadata`) on a Unix
  socket, flag `--service-account-signing-endpoint`, gate `ExternalServiceAccountTokenSigner` GA
  and locked on. The flag is mutually exclusive with `--service-account-key-file`, so during the
  move to the signer, the signer must publish the old file key (and the legacy-token key, as
  `exclude_from_oidc_discovery`).
- Two `service-account-key-file` entries in a Kind `kubeadmConfigPatches` collapse into one and
  replace the default `sa.pub`, which broke the cluster. Rotation steps therefore edit the
  static pod manifests on each control plane.
- During a rolling flag change, API servers behind the load balancer serve different JWKS (two
  `kid`s on the edited one, one on its peer). External verifiers fetching through the load
  balancer see whichever they hit.

## Resume

```bash
cd docs/labs/sakeyroll
bash scripts/00-tools.sh && bash scripts/00b-start-dockerd.sh
export PATH=/usr/local/go/bin:~/bin:$PATH
kind build node-image --type release v1.37.2 --image kindest/node:v1.37.2
bash scripts/01-preflight.sh
```
