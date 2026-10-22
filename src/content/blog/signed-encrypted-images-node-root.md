---
title: 'I signed and encrypted every image. Then I logged into the node as root'
description: 'Part 1 of 2. Cosign signatures, SBOM and provenance attestations, Kyverno enforcement and ocicrypt-encrypted layers, all tested on Kind. Then the same images, attacked by someone with root on the node.'
pubDate: 2026-10-22
tags: ['kubernetes', 'security', 'supply-chain', 'cosign', 'kyverno']
---

The pod that got through my admission policy said `EVIL secret-len=16`.

That string is mine. I put it in a deliberately bad build of a tiny Go service, pushed it to
my registry unsigned, and pointed the `:v1` tag at it. The policy in front of the cluster
requires a cosign signature, a CycloneDX SBOM and a SLSA provenance attestation from my key
before any image runs in `prod`. It had denied that exact image, by digest, a few seconds
earlier. Then it let it in under the tag, pinned it to the evil digest, and the kubelet started
it with the production secret in its environment.

Nothing errored. The policy reported Ready the whole time.

This is the first of two posts about a question I keep getting from teams hardening their
Kubernetes supply chain: once you sign everything and encrypt the layers, what is actually left
to protect? I built the whole stack on a Kind cluster and asked three things:

1. **Does admission enforcement block what it claims to?** Unsigned images, tampered
   signatures, a repointed tag, a registry outage. How many get through, and what does
   verification cost per pod?
2. **What does layer encryption buy you?** A stolen copy of the registry, a node that doesn't
   hold the key, and the pull/start overhead compared with a plain image.
3. **What does root on one node get an attacker?** Decrypted image contents, process secrets,
   memory, the decryption key itself. Exact commands, timed.

Same rule as last time: **if I didn't observe it, it isn't here.** Scripts and raw output are in
[`docs/labs/signed-encrypted-images-node-root/`](https://github.com/netf/blog/tree/main/docs/labs/signed-encrypted-images-node-root),
and `./reproduce.sh` rebuilds everything from a blank VM.

Part 2 is about the obvious answer to question 3, confidential containers and TEEs. I meant to
test them here and couldn't; the methodology section says why in two lines.

## The short version

- **The signature checks themselves are solid.** Unsigned images, by tag or digest, and a valid
  signature transplanted onto another image were all denied. Full verification of a signature and
  two attestations cost 43 ms per pod at the median against a local registry.
- **cosign v3 and Kyverno's default settings don't agree on where signatures live.** A correctly
  signed image was denied with `no signatures found` until I set `type: SigstoreBundle`.
- **A repointed tag rides the verification cache.** Kyverno caches "verified" against the tag
  string for up to 60 minutes, then pins whatever digest the tag points to now. With a 2-minute
  TTL the unsigned image was admitted for 104 to 106 seconds. Digest references and a disabled
  cache both closed it. The Helm chart silently drops `imageVerifyCacheEnabled=false` unless you
  pass it as a string.
- **Kyverno fails closed when it crashes and open when it's stopped politely.** After a
  graceful scale-down its webhooks were gone within 2 seconds and an unsigned pod was admitted.
- **Encrypted layers stop registry theft and little else.** A stolen copy didn't contain the
  model, but its config, build history, `diff_ids` and exact layer sizes were plaintext. A node
  without the key couldn't pull the image, unless it had already run the plain version. Then it
  ran it in 10 ms.
- **Root on the node got everything on that node in 8.3 seconds:** the env secret, the mounted
  Secret, the decrypted model from disk (still there after the pod was deleted), the decryption
  key, a decrypted copy of the registry image, and a memory dump. The kubelet's own credentials
  couldn't read a Secret that no pod on that node mounts.

## How the pieces fit

Signing and encryption protect different hops, and neither one protects the node itself:

```mermaid
flowchart LR
  B[Build: docker build] -->|push index digest| REG[(Registry)]
  S[cosign sign + attest<br/>SBOM, SLSA provenance] -->|referrer: sigstore bundle| REG
  ENC[skopeo --encryption-key jwe:pub] -->|layers +encrypted| REG
  API[kube-apiserver] -->|AdmissionReview| K[Kyverno verifyImages]
  K -->|1. cache lookup by policy + image ref| C{{verify cache, TTL 60m}}
  K -->|2. on miss: fetch bundle, verify| REG
  K -->|3. mutateDigest: resolve tag now| REG
  API --> KL[kubelet on node]
  KL --> CT[containerd + ctd-decoder]
  CT -->|pull ciphertext| REG
  KEY[/node key: /etc/containerd/ocicrypt/keys/] --> CT
  CT --> SNAP[(overlayfs snapshots: plaintext)]
  SNAP --> P[container process: env, memory, mounted secrets]
```

Admission decides *whether* a pod may run, using signatures fetched from the registry.
Encryption decides *who* can read the layers on the way to the node. Once containerd has
decrypted them, the plaintext lives on the node's disk and in the process, next to the key that
decrypted it. Steps 1 and 3 in the diagram are where the surprise below comes from.

## The lab

One Kind cluster (`supply`: a control plane and two workers, Kubernetes v1.37.0, containerd
2.3.4) on a 4-vCPU VM, plus a plain-HTTP `registry:2.8.3` on the Kind network at
`kind-registry:5000`. The same name resolves on the host, on the nodes and inside pods, which
matters because Kyverno fetches signatures from inside a pod.

- **The app** is a 5.8 MB (5,767,330-byte) static Go binary in a `scratch` image, plus an 8 MiB "proprietary
  model" file whose first line is `PROPRIETARY-MODEL-MARKER-7f3a9c`. That marker is how I check
  later whether someone can read the image. The app copies `APP_SECRET` from its environment
  into a package variable, so the secret also lives in its heap.
- **Signing:** cosign v3.1.3 with a local key pair, no Fulcio and no Rekor. syft v1.54.1 makes
  the CycloneDX SBOM; the SLSA v1 provenance predicate is hand-written and names a builder ID
  the policy checks.
- **Admission:** Kyverno v1.19.1 (chart 3.9.1), one `ClusterPolicy` scoped to namespace `prod`
  that requires the signature and both attestations and rewrites tags to digests.
- **Encryption:** skopeo 1.13.3 `--encryption-key jwe:` (RSA-4096) and imgcrypt v2.0.3's
  `ctd-decoder` as containerd's stream processor, with the private key on `supply-worker` only.
- **The attacker** in part 3 is `docker exec supply-worker`, which on Kind is the same thing as a
  root shell on the node.

## 1. Admission: what the policy actually blocks

### First, my correctly signed image was rejected

cosign v3 changed where signatures go. `cosign sign` now writes a Sigstore bundle
(`application/vnd.dev.sigstore.bundle.v0.3+json`) as an OCI 1.1 *referrer* of the image. My
`registry:2.8.3` has no referrers API, so cosign fell back to a tag named after the digest,
`sha256-<digest>`, with no `.sig` suffix. cosign itself verified the signature and both
attestations without complaint.

Kyverno, with the policy's `type` left at its default (`Cosign`), denied the image:

```text
failed to verify image kind-registry:5000/demo/app:v1:
.attestors[0].entries[0].keys: no signatures found
```

Setting `cosignOCI11: true` (described in the CRD as "the experimental OCI 1.1 behaviour")
produced the same error. What worked was `type: SigstoreBundle` on the `verifyImages` entry.
To make sure that wasn't a policy accepting anything, I changed the expected builder ID in the
provenance condition and the same image was denied with
`image attestations verification failed, verifiedCount: 0, requiredCount: 1`.

This failure is the safe kind: a format mismatch fails closed. But if you upgrade cosign in CI
and not your policies, every newly signed image is denied, and the error message points at your
signatures rather than at the policy.

### The attack matrix

With `type: SigstoreBundle`, I threw the obvious attacks at it. Each row is one `kubectl run` in
`prod` (`results/admission/attacks.tsv`):

| Attempt | What the attacker did | Result |
|---|---|---|
| Signed image by tag | nothing (control) | allowed |
| Signed image by digest | nothing (control) | allowed |
| Unsigned image by tag | pushed `:evil`, never signed | **denied** |
| Unsigned image by digest | same image, `@sha256:` | **denied** |
| Transplanted signature | copied v1's valid bundle onto an unsigned image's referrer tag (raw manifest `GET` + `PUT`, HTTP 201) | **denied**: `sigstore bundle verification failed: no matching signatures found` |
| Repointed tag | overwrote `:v1` so it resolves to the unsigned image | **allowed**, pinned to the unsigned digest |
| Signed digest after repoint | `@sha256:` of the real v1 | allowed |

Six of seven rows behave the way the brochure says. The bundle binds the digest it signed, so a
copied signature is useless, and anything referenced by digest can't be swapped underneath you.

The repointed tag is the row from the opening.

### The tag that stayed verified

My first guess was that `85d20…`, the digest in that run, had somehow picked up a valid
signature. `cosign verify` said `no signatures found`. Then I restarted the Kyverno admission
controller and retried the same tag. Denied.

So it was state, and the binary documents it:

```text
-imageVerifyCacheEnabled     Enable a TTL cache for verified images. (default true)
-imageVerifyCacheMaxSize     ... Keys are a combination of policy elements along with
                             the image reference. Default is 1000.
-imageVerifyCacheTTLDuration ... Default is 60m.
```

The cache key is the image reference as written in the pod spec, `kind-registry:5000/demo/app:v1`,
and not the digest it resolved to. When the signed `:v1` is admitted, "verified" is cached against
the string `…/app:v1`. When the tag moves, the next pod with that string hits the cache, skips
verification, and then `mutateDigest` resolves the tag again and pins whatever it points to
*now*. Verification and digest resolution are two separate lookups, and the cache sits between
them.

`scripts/13-repoint-cache.sh` reproduces it: admit `:v1`, repoint `:v1`, keep admitting:

| Kyverno setting | Repointed tag admitted until | First denial |
|---|---|---|
| `imageVerifyCacheTTLDuration=2m` (run 1) | t=104 s | t=124 s |
| `imageVerifyCacheTTLDuration=2m` (run 2) | t=106 s | t=126 s |
| default (60m TTL), polled every 2 min | still admitted at t=483 s, the last poll before the VM went away | not reached |
| `imageVerifyCacheEnabled=false` | never | t=0 s |

The first admitted pod in each run really was the evil build: a probe pod's `wget` of
`/whoami` returned `EVIL secret-len=16`, and the kubelet reported the unsigned digest as its
`imageID`. In the 2-minute runs, a cache hit every 20 seconds did not extend the window; it
closed one TTL after the legitimate `:v1` was verified. So anyone who can push a tag gets up to
an hour (the default TTL) of unverified deploys of that tag after it was last verified.

The fix is one flag, and the chart ate it the first time. Kyverno's chart renders extra args
like this:

```yaml
{{- range $key, $value := .Values.admissionController.container.extraArgs }}
{{- if $value }}
- --{{ $key }}={{ $value }}
{{- end }}
{{- end }}
```

`--set admissionController.container.extraArgs.imageVerifyCacheEnabled=false` makes `$value`
the boolean `false`, the `if` drops it, and the cache stays on. No warning; the repointed tag was
still admitted in that run (`results/repoint-cache/off-bool-dropped-by-chart/`). Pass it as a
string with `--set-string`, then check that `--imageVerifyCacheEnabled=false` is actually in the
container args.

### What verification costs per pod

`scripts/15-latency.sh` times `kubectl create --dry-run=server` for a pod. Dry-run runs the
whole admission chain, verification and digest mutation included; the script aborts if a dry-run
of the unsigned image is *not* denied. 30 samples per case, wall time in ms, local registry:

| Case | p50 | p90 | p99 | max |
|---|---|---|---|---|
| No policy (namespace `default`) | 66 | 70 | 84 | 87 |
| Policy, verify-cache hit | 71 | 76 | 96 | 103 |
| Policy, cache disabled (full signature + 2 attestation checks) | 109 | 117 | 127 | 130 |

So full verification adds about 43 ms at the median against a registry on the same Docker
network. Turning the cache off costs 38 ms per pod over a warm cache. A registry across a WAN
will add its round trips on top, and I didn't test that.

### When things are down: fail-closed, mostly

The registry tests pause the registry container (`docker pause`), so connections hang rather
than get refused. The Kyverno tests take the admission controller away two ways: a normal
scale-down to zero, and a `kill -9` of its process (`scripts/14*.sh`).

| Situation | Unsigned or signed? | Result | Time |
|---|---|---|---|
| Registry hung, cold cache, by tag | signed | denied: webhook `context deadline exceeded` | 15,043 ms |
| Registry hung, warm cache, by tag | signed | denied, same timeout | 15,039 ms |
| Registry hung, warm cache, **by digest** | signed | allowed | 54 ms |
| `failureAction: Audit` | unsigned | **allowed**, client gets a `Warning:` line | 57 ms |
| `failureAction: Audit`, registry hung | signed | denied, same timeout | 15,042 ms |
| Kyverno `kill -9`'d, `failurePolicy: Fail` | unsigned | denied: `connection refused` | 47 ms |
| Kyverno **scaled to 0**, `failurePolicy: Fail` | unsigned | **allowed** | 44 ms |
| Kyverno scaled to 0, `failurePolicy: Ignore` | unsigned | allowed | 46 ms |

Three of these surprised me.

**A warm cache doesn't save a tag from a registry outage.** It covers verification, but
`mutateDigest` still has to ask the registry what the tag points to, and that call hangs until
the 15-second webhook timeout. The same signed image by digest went straight through. So
digest references make you both safer (no repointing) and more available.

**Audit mode can't pin digests, and it isn't fail-open either.** Kyverno's own policy validation
refused my Audit policy with `mutateDigest must be set to false for 'Audit' failure action`. So
Audit means unsigned images run *and* tags stay mutable. Yet with the registry hung, Audit still
denied a signed pod after 15 seconds, because a webhook timeout is governed by `failurePolicy`,
not by `failureAction`.

**A graceful Kyverno shutdown removes the enforcement, not just the enforcer.** Before the
scale-down there were two `kyverno-resource-*` webhook configurations. Two seconds after it, zero,
so `failurePolicy: Fail` had nothing to apply to and the unsigned pod was admitted. They came back
5 to 10 seconds after the new pod was ready. A crash leaves the webhooks in place, and those fail
closed. So the dangerous outage is the polite one. I only tested `kubectl scale`; I'd expect anything
else that stops a single replica gracefully, such as draining its node, to behave the same.

## 2. Encrypted layers: what a stolen registry gets you

`skopeo copy --encryption-key jwe:enc-pub.pem` re-wrote both layers as
`application/vnd.oci.image.layer.v1.tar+gzip+encrypted`. Each layer gets a random symmetric key
(`AES_256_CTR_HMAC_SHA256`, per the layer's `pubopts` annotation), and that key is wrapped with
my RSA public key into a 1,460-character `org.opencontainers.image.enc.keys.jwe` annotation.

Then I played someone who has read access to the registry, or a copy of its storage, and no
private key (`scripts/21-stolen-copy.sh`):

| | plain copy | encrypted copy |
|---|---|---|
| `tar tzf` on each layer blob | lists `demoapp`, `opt/model/model.bin` | `gzip: stdin: not in gzip format` |
| marker found after `gunzip` | 1 | **0** |

The contents are protected as advertised. What's around them isn't:

- **The image config is plaintext, and it's the same blob.** The encrypted image points at the
  identical config digest as the plain one. It shows the entrypoint, the user (`65532:65532`)
  and the build history, including `COPY model.bin /opt/model/model.bin # buildkit`.
- **`diff_ids` are hashes of the plaintext.** The config's `rootfs.diff_ids` equal the SHA-256
  of each *decrypted* layer tar; I checked both against the plain image. If an attacker can guess
  a layer (a public base image, last quarter's model), they can confirm the guess without the key.
- **Sizes are exact.** Ciphertext layers are byte-for-byte the same length as the plaintext ones
  (8,391,419 bytes for the model layer in the final run).

### A node without the key, and a node that already had the layers

Both workers got `ctd-decoder` as containerd's stream processor (`key_model = "node"`); only
`supply-worker` got the private key. `scripts/23-run-encrypted.sh` wipes every demo image from a
node and checks that no `model.bin` is left in its snapshots before each case:

| Node | Before the pod | Result |
|---|---|---|
| `supply-worker2` (no key) | clean | `ErrImagePull`: `call to DecryptLayer failed: missing private key needed for decryption` |
| `supply-worker2` (no key) | ran `app-plain:v1` first | **Running**. Pull took 10 ms |
| `supply-worker` (key) | clean | Running, pull 118 ms |

The second row is because encryption doesn't change the image's identity. Plain and encrypted
images have the same config blob, so the same `diff_ids` and the same snapshot chain, and the
10 ms pull is what you'd expect if containerd reused the unpacked snapshots instead of fetching
and decrypting anything. My first, uncontrolled run of this test had the keyless node running the
encrypted image too, before I worked out why. A node that has unpacked the plaintext layers, from
the plain image or from another image that shares them, doesn't need the key for those layers.

The overhead is small. Cold pull and start on the keyed node, clean before every sample, N=10,
10.9 MB image:

| | pull (kubelet event), median | min-max | create to Ready, median | min-max |
|---|---|---|---|---|
| plain | 78 ms | 64-83 | 584 ms | 565-863 |
| encrypted | 116 ms | 104-129 | 628 ms | 602-645 |

About 38 ms more to pull and 44 ms more to Ready, at this size. I only tested this one 10.9 MB
image, so I don't know how the gap scales with multi-gigabyte layers.

## 3. Root on the node

The victim is the encrypted app on `supply-worker`, the node with the key, with
`APP_SECRET=env-secret-value-77aa` in its environment and a Secret `db-creds` mounted at
`/var/run/creds`. The attacker has a root shell on that node and nothing else: no kubeconfig, no
registry credentials. Each step is one command, timed around `docker exec`
(`scripts/30-node-root.sh`, output in `results/node-root/`):

| # | What | Command (inside the node unless noted) | ms | Got |
|---|---|---|---|---|
| 1 | find the process | `crictl inspect --output go-template --template '{{.info.pid}}' $(crictl ps -q --label io.kubernetes.pod.name=victim)` | 83 | PID |
| 2 | environment | `tr '\0' '\n' < /proc/$PID/environ` | 82 | `APP_SECRET=env-secret-value-77aa` |
| 3 | mounted Secret | `cat /proc/$PID/root/var/run/creds/password` | 77 | `s3cr3t-db-password-4b1d` (a tmpfs, so memory, not disk; root reads it anyway) |
| 4 | decrypted image, live | `head -c 31 /proc/$PID/root/opt/model/model.bin` | 73 | the marker |
| 5 | decrypted image, on disk | `head -c 31 /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/*/fs/opt/model/model.bin` | 53 | the marker, in `snapshots/243/fs` |
| 6 | the decryption key | `cat /etc/containerd/ocicrypt/keys/enc-priv.pem` | 29 | a 3,272-byte RSA private key |
| 7 | decrypt the registry copy | on the attacker's machine: `skopeo copy --decryption-key stolen.pem docker://…/app-enc:v1 dir:dec`, then grep | 155 | the marker |
| 8 | process memory | on the host: `gcore` the app, `strings` the core | 7,406 | the env secret, 2 occurrences |
| 9 | kubelet identity, mounted Secret | `kubectl --kubeconfig /etc/kubernetes/kubelet.conf -n enc get secret db-creds` | 121 | the password |
| 10 | kubelet identity, other Secret | same, `unrelated-secret` | 87 | `Forbidden` |
| 11 | kubelet identity, list | `get secrets -A` | 126 | `Forbidden` |
| 12 | after `kubectl delete pod victim` | step 5 again | 54 | the marker, still on disk |

All twelve took 8.3 seconds, 7.4 of them waiting for `gcore`.

None of this is an exploit. It's the node doing its job. To run the container, containerd had
to decrypt the layers, so plaintext sits in the snapshot directory for as long as the image is
cached, not just while the pod runs. To decrypt them, the key had to be on the node, so root has
it, and with it every copy of the image anywhere, including the "stolen registry" from part 2.
The process has its secrets in its environment and memory because that's how it uses them.

The one boundary that held is the Kubernetes API. The kubelet's credentials are confined by the
Node authorizer to Secrets that pods on that node mount: `db-creds` yes, `unrelated-secret` and `list` no
(`node: no relationship found between node 'supply-worker' and this object`). So root on one node gets that node's workloads, its decryption keys and its pods'
Secrets, not the cluster's.

Signing didn't help here at all, and wasn't meant to. It answers "is this the image I built?",
which is already settled by the time an attacker is reading `/proc`.

## Appendix A: Methodology

- **Scope.** One Kind cluster on one 4-vCPU VM, a local plain-HTTP registry, a key-based cosign
  flow without Fulcio or Rekor, Kyverno's `ClusterPolicy` API (deprecated in 1.19 in favour of
  `ImageValidatingPolicy`, which I didn't test), and node-model key distribution for ocicrypt.
  "Root on the node" means `docker exec` into the Kind node container, which gives the same
  filesystem, process and kubelet view a root shell on a real node would.
- **Why there's no TEE here.** The VM is a Firecracker microVM. `/proc/cpuinfo` shows `vmx` and
  `hypervisor` but none of `sev`, `sev_snp`, `tdx_guest` or `sgx`, there is no
  `/sys/hypervisor` and no `/dev/vhost-vsock`, and an earlier run found that `KVM_CREATE_VCPU`
  hits `kernel BUG at arch/x86/kvm/x86.c:702` (`kvm_spurious_fault`). Confidential Containers
  needs a working nested hypervisor at minimum, so it's part 2, on different hardware. This lab
  ran no KVM, QEMU or Kata probes.
- **Runs.** Parts 1 and the stolen-copy test ran on two blank VMs (2026-10-15 and 2026-10-22),
  with different keys and digests and the same outcomes. The node-side encryption tests and the
  node-root attack ran on the second VM. Tables show the second run unless marked.
- **Timing.** Admission latency is client wall time of `kubectl create --dry-run=server`, so it
  includes about 66 ms of client and API-server overhead that's present in every case.
  Node-root steps are timed around each `docker exec`, which adds its own startup cost.
