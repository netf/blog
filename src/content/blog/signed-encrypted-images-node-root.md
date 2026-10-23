---
title: 'I signed and encrypted every image. Then I logged in as root and read everything.'
description: 'What image signing, attestations, admission policies and encrypted layers actually protect — measured on a real cluster, then attacked from the inside.'
pubDate: 2026-10-22
updatedDate: 2026-10-23
tags: ['kubernetes', 'security', 'supply-chain', 'cosign', 'kyverno']
---

There is a checklist that security teams hand out for container images, and it sounds convincing.

Sign every image, so you can prove where it came from. Add attestations, so you can prove how it
was built. Encrypt the layers, so that a stolen copy of your registry is useless. Then put a
policy in front of the cluster that refuses anything that doesn't match.

Do all of that, the reasoning goes, and your software supply chain is safe.

I wanted to know what "safe" means in practice. So I built the whole stack on a small test
cluster — a five-megabyte service, a fake proprietary model, a private registry, and the same
tools a real team would use — and then I attacked it. First from the outside, the way an
intruder would. Then from inside, with root on one of the machines.

The front door held. The back door was open, and walking through it took eight seconds.

That is not an argument against signing or encryption. Both did exactly what they promise. The
problem is that we have quietly stretched "supply chain security" to cover something the tools
never claimed: the machine that runs your code.

## What I found

**Signing works.** Unsigned images were refused. A valid signature copied onto a different image
was refused. So was every other forgery I tried. Checking a signature plus two attestations added
about 43 milliseconds per pod.

**A tag is the crack in the wall.** The policy checks the name you wrote in the manifest. If that
name is a tag like `:v1`, the cluster can verify one image and then run another, because the tag
can be moved after the check. By default it remembers the tag, not the image, for up to an hour.
I moved a tag and got an unsigned image into production.

**Encryption protects the registry, not the machine.** A stolen copy of my registry was
unreadable, as promised. But the image's configuration, build history and layer hashes were
still readable. And a machine that had already run the unencrypted version could run the
encrypted one without the key.

**Root on a machine owns everything on it.** In 8.3 seconds I read the application's environment
secrets, a mounted password, the decrypted model on disk, the decryption key, and a copy of the
process's memory. The only thing I could not read was a Secret belonging to a pod that was not
running there.

**A polite shutdown is a security hole.** When I shut the policy engine down the normal way, it
took its enforcement with it, and unsigned pods ran. When I killed it abruptly, it failed safe.

## What each piece is supposed to do

Five different things usually travel together under the name "supply chain security". They solve
different problems, and keeping them apart makes the rest of this post easier to follow.

A **signature** is a wax seal. It proves that the image came from the key you trust and that
nobody changed it on the way. An **attestation** is the same idea applied to facts about the
build: this SBOM lists the libraries, this provenance record says which builder produced it.

A **digest reference** is an image's fingerprint rather than its name. `:v1` is a label that
someone can move; `@sha256:…` always means those exact bytes.

An **admission policy** is the guard at the door. Before a pod starts, the guard asks the
registry for the signature and refuses the pod if it doesn't match.

**Encrypted layers** are a locked case. Anyone can take the case from the registry, but only
someone with the key can open it, so a stolen copy of the registry is not a stolen copy of your
software.

The **machine running the container** is the building. Everything above is about getting the
right package through the door. None of it says much about what happens once the package is
inside and opened.

That distinction is the whole story of this post:

| The piece | What it promises | What I actually found |
|---|---|---|
| Signature and attestations | "This is the image I built, and I can prove how." | Held. Every unsigned or copied signature was rejected. |
| Digest reference | "Exactly these bytes, and no others." | Held when used. Tags are the way around it. |
| Admission policy | "Nothing runs unless it matches." | Held until the policy is unavailable, or the tag moves. |
| Layer encryption | "A stolen registry copy is unreadable." | Held for the contents. Everything around them stayed readable. |
| The machine boundary | "Workloads are separated from each other." | Held for the Kubernetes API. Not for root on the machine. |

The rest of this post is the evidence for that table.

## The setup

Everything ran on one Kind cluster — Kubernetes running inside Docker on a single four-core
virtual machine — with a control plane and two workers. A private registry lived on the same
network, reachable by the same name from the host, the machines and the pods. That last part
matters, because the policy engine fetches signatures from inside a pod.

The application is small on purpose. It is a 5.8 MB Go binary plus an 8 MiB file I called a
"proprietary model". The first line of that file reads `PROPRIETARY-MODEL-MARKER-7f3a9c`, and
that marker is how I checked whether someone could read the image. The application also copies
its environment secret into memory, so the secret exists in two places.

Around it sat the stack a team would run: cosign for signing, syft for the SBOM, a provenance
record, Kyverno for admission, and skopeo with imgcrypt for encryption, with the private key
installed on one worker only.

The attacker at the end is a root shell on that worker. On Kind, that is the same as root on a
real node: the same files, the same processes, the same credentials.

If I didn't observe it, it isn't in here. The scripts and raw output are in the
[lab repository](https://github.com/netf/blog/tree/main/docs/labs/signed-encrypted-images-node-root),
and one script rebuilds everything from a blank machine.

## The front door: can the policy be fooled?

I started where an outsider would start: with an image the cluster had never seen, pushed to a
registry I controlled.

### The guard refused my own badge first

Before I could test an attack, my correctly signed image was rejected.

Signing tools had recently changed where they keep signatures. cosign v3 writes a "bundle" next
to the image instead of the older detached signature. My registry was a plain `registry:2.8.3`
image, which does not support the newer lookup, so cosign fell back to a tag named after the
image digest. cosign itself was happy: it verified the signature and both attestations without
complaint.

Kyverno was not. It looked in the old place and reported that it found no signatures at all.

A policy setting that the documentation calls "the experimental OCI 1.1 behaviour" did not help.
What worked was telling the policy that signatures arrive as bundles, with one line:
`type: SigstoreBundle`.

To be sure that was not a policy accepting everything, I changed the expected builder name in the
provenance check. The same image was then refused for having no valid attestation, which is the
correct answer.

The failure was safe. But it was also the kind of failure that costs an afternoon. If you upgrade
cosign in your build pipeline and not your policies, every new image is rejected, and the error
message blames your signatures rather than your configuration.

### What got through

With the policy reading bundles, I tried the attacks that matter. Each row was one attempt to
start a pod in `prod`.

| What I tried | How | Result |
|---|---|---|
| A normal signed image, by tag | control | allowed |
| A normal signed image, by digest | control | allowed |
| An unsigned image, by tag | pushed `:evil`, never signed | **refused** |
| An unsigned image, by digest | the same image, referenced by hash | **refused** |
| A forged signature | copied a valid signature onto the unsigned image | **refused** |
| A moved tag | pointed `:v1` at the unsigned image | **allowed**, and pinned to the unsigned image |
| A signed image, by digest, after the move | the original image, referenced by hash | allowed |

Six of seven behaved the way the documentation says they should. The signature is tied to the
exact image it signed, so copying it elsewhere is useless. An image referenced by hash cannot be
swapped underneath you.

The seventh is the one that worked, and it deserves its own section.

### The tag that kept its trust

My first assumption was that the unsigned image had somehow acquired a valid signature. It had
not; cosign confirmed there was nothing to find. I restarted the policy engine and tried the same
tag again. This time it was refused.

So the problem was not the signature. It was memory. Kyverno keeps a cache of images it has
already verified. The cache defaults to one hour, and the key it stores is the image reference as
written in your manifest — not the image it resolves to.

When `app:v1` passed verification, the cache recorded "app:v1 is fine". Later, the tag was
pointed at a different image. The next pod asked for `app:v1`, matched the cache, skipped
verification, and then a separate step resolved the tag again and pinned whatever it found.
Verification and resolution are two different lookups, and the cache sits between them.

I reproduced it by admitting `:v1`, moving the tag, and continuing to deploy:

| Policy setting | How long the moved tag was admitted | When it was finally refused |
|---|---|---|
| Cache lifetime 2 minutes, first run | 104 seconds | 124 seconds |
| Cache lifetime 2 minutes, second run | 106 seconds | 126 seconds |
| Default 60-minute cache, checked every 2 minutes | still admitted at 483 seconds, the last check before the machine was torn down | never observed |
| Cache disabled | never admitted | immediately |

The first admitted pod really was the bad build: a test request came back with the string I had
hard-coded into that build, and the node reported the unsigned image's hash as the one running.
In the two-minute runs, checking every 20 seconds did not extend the window. It closed one
cache lifetime after the good image was last checked.

**So anyone who can push a tag gets up to an hour of deploys of whatever that tag points at.**
That is the default behaviour, not a misconfiguration.

There is a fix: turn the cache off. It comes with a trap. The Helm chart that installs Kyverno
treats the boolean `false` as an empty value and silently drops the flag, so you have to pass it
as the string `"false"` and then check the running container's arguments to be sure it arrived.
I made that mistake once, and the moved tag was still admitted in that run.

### What the checking costs

A signature check is worth having only if it is cheap enough to leave on. I measured it by
creating a pod with a server-side dry run, which runs the entire admission chain without
starting anything. Thirty samples per case, against a registry on the same network:

| Case | Median | 90th percentile | Worst |
|---|---|---|---|
| No policy at all | 66 ms | 70 ms | 87 ms |
| Policy, with a warm cache | 71 ms | 76 ms | 103 ms |
| Policy, cache disabled, full verification | 109 ms | 117 ms | 130 ms |

Full verification adds about 43 milliseconds to the median. Turning the cache off costs another
38 milliseconds against a warm cache. A registry across the internet would add its own round
trips, which I did not test.

### When the guard goes away

The interesting failures were not attacks. They were outages.

I tested two kinds. For the registry, I paused the container so that connections hung instead of
being refused, which is closer to a real network partition. For the policy engine, I took it away
two ways: a normal scale-down to zero, and a hard kill.

| Situation | Image | Result | Time |
|---|---|---|---|
| Registry frozen, cold cache, by tag | signed | refused, request timed out | 15.0 s |
| Registry frozen, warm cache, by tag | signed | refused, same timeout | 15.0 s |
| Registry frozen, warm cache, **by digest** | signed | allowed | 54 ms |
| Audit mode instead of enforce | unsigned | **allowed**, with a warning | 57 ms |
| Audit mode, registry frozen | signed | refused, same timeout | 15.0 s |
| Policy engine hard-killed | unsigned | refused, connection rejected | 47 ms |
| Policy engine scaled to zero | unsigned | **allowed** | 44 ms |
| Policy engine scaled to zero, ignore failures | unsigned | allowed | 46 ms |

Three results surprised me.

**A warm cache does not survive a registry outage.** The cache covers verification, but the
policy still has to ask the registry what the tag points at, and that request hangs until the
15-second timeout. The same image, referenced by digest, went straight through. Digest references
make you both safer and more available.

**Audit mode is not the safety valve people think it is.** Kyverno refuses to pin digests in
audit mode, so unsigned images run *and* tags stay mutable. At the same time, a registry timeout
still blocks a signed pod, because timeouts are governed by a different setting than policy
violations.

**A graceful shutdown removes the enforcement, not just the enforcer.** Before the scale-down
there were two webhook configurations telling Kubernetes to call Kyverno. Two seconds after it,
there were none, so a "fail closed" policy had nothing left to fail closed. They came back five
to ten seconds after the replacement pod was ready. A hard kill leaves the webhooks in place, and
those do fail closed.

That last one is the uncomfortable conclusion: **the dangerous outage is the polite one.** I only
tested `kubectl scale`, but I would expect anything that stops a single replica gracefully, such
as draining its node, to behave the same way. With two replicas, deleting one of them left both
webhooks in place, and unsigned pods were refused throughout. The chart warns you about running
fewer than two. It is worth taking literally.

## The locked box: what encryption hides

Now the second promise: if someone steals your registry, they get nothing.

Encryption works by re-writing each layer so that it can only be opened with a key. skopeo did
that with an RSA public key. Each layer got its own random symmetric key, and that key was
wrapped with the public key and stored in an annotation on the image.

I then played the part of someone with read access to the registry, or a copy of its disk, and no
private key:

| What I tried | Plain image | Encrypted image |
|---|---|---|
| List the contents of each layer | shows the binary and the model file | `not in gzip format` |
| Search for the marker after decompressing | found | **not found** |

So the contents are protected. What sits around the contents is not.

### What the encryption does not hide

**The configuration is plain text, and it is shared.** The encrypted image points at exactly the
same configuration file as the plain one. That file shows the entrypoint, the user the container
runs as, and the build history, including the line that copied the model into the image.

**The layer hashes are hashes of the plain text.** The configuration lists a digest for every
decrypted layer. I checked both against the unencrypted image and they matched. If an attacker
can guess a layer, a public base image or last quarter's model, they can confirm the guess
without the key.

**The sizes are exact.** Encrypted layers are byte-for-byte the same length as the plain ones.
The model layer was 8,391,419 bytes in the final run, and that number alone tells you something.

None of this is a bug. It is the cost of keeping the image a normal OCI image. But it means
encryption protects the contents of the box, not the fact that you shipped a box of that shape.

### The machine that didn't need the key

This was the result I did not expect.

I installed the decryption key on one worker only. The other worker had the decoder, but no key.
Wiped clean, it refused to pull the encrypted image, exactly as it should:

| Worker | State before starting | Result |
|---|---|---|
| No key | clean | refused: missing private key |
| No key | had already run the plain image | **started in 10 ms** |
| Key installed | clean | started, pulled in 118 ms |

The second row is the important one. Encryption does not change the image's identity: the plain
and encrypted versions share a configuration, which means they share layer hashes and therefore
share the unpacked layers on disk. A machine that has already unpacked the plain text does not
need the key for those layers. It just reuses them.

My first run of that test was uncontrolled, and the keyless worker ran the encrypted image
before I understood why. That is worth saying plainly, because the mistake is easy to make when
you test this yourself.

### What encryption costs

At this size, not much. Cold pull and start on the worker with the key, ten samples, a 10.9 MB
image:

| | Pull, median | Create to ready, median |
|---|---|---|
| Plain | 78 ms | 584 ms |
| Encrypted | 116 ms | 628 ms |

About 38 milliseconds more to pull and 44 more to reach ready. I only tested one image at this
size, so I cannot tell you how the gap grows with multi-gigabyte layers.

## The back door: root on one machine

Here is where the story changes. Everything above is about an attacker outside the cluster. This
part is about someone who already has root on one of the machines.

The victim was the encrypted application on the worker that had the key. It had a secret in its
environment and a password mounted as a file. The attacker had a root shell and nothing else: no
cluster credentials, no registry credentials, no application code.

I wrote down twelve things to try, in the order an impatient person would try them. Each took one
command:

| Step | What I did | Time | What I got |
|---|---|---|---|
| 1 | Found the container's process | 83 ms | its process ID |
| 2 | Read its environment | 82 ms | the application secret |
| 3 | Read the mounted password | 77 ms | the database password |
| 4 | Read the model through the running process | 73 ms | the marker |
| 5 | Read the model from disk | 53 ms | the marker, in a snapshot directory |
| 6 | Read the decryption key | 29 ms | a 3,272-byte private key |
| 7 | Decrypt the registry copy on another machine | 155 ms | the marker |
| 8 | Dump the process's memory | 7.4 s | the secret, twice |
| 9 | Use the node's credentials on its own Secret | 121 ms | the password |
| 10 | Try the same on an unrelated Secret | 87 ms | forbidden |
| 11 | List every Secret in the cluster | 126 ms | forbidden |
| 12 | Read the disk again after deleting the pod | 54 ms | the marker, still there |

All twelve took 8.3 seconds. 7.4 of those were waiting for the memory dump.

None of this is an exploit. It is the machine doing its job.

To run the container, containerd had to decrypt the layers, so the plain text sits in the
snapshot directory for as long as the image is cached, not just while the pod is running. To
decrypt them, the key had to be on the machine, so root has it, and with it every copy of the
image anywhere, including the "stolen registry" from the previous section. The process keeps its
secrets in its environment and its memory because that is how it uses them. Deleting the pod
removes the process, not the unpacked image.

One boundary did hold: the Kubernetes API. The credentials that the node uses are limited to
Secrets that pods on that node actually mount. The mounted password was readable. An unrelated
Secret, and a cluster-wide list, were refused. So root on one machine gets that machine's
workloads, its keys and its pods' Secrets. It does not get the cluster.

Signing did not help here, and was never meant to. A signature answers "is this the image I
built?" That question was settled long before the attacker opened a shell.

## What this means for your own cluster

My numbers describe my cluster, not yours. Four questions will tell you whether the same gaps
exist in yours.

**Does every image reference a digest?** If every manifest uses `@sha256:…`, the moved tag and
the cache window do not apply. A single tag reopens both. You can list every image running in the
cluster, and anything without `@sha256:` is a tag:

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}'
```

**Would a freshly signed image pass your policy today?** Sign a throwaway image with the same
cosign version your build pipeline uses, and try to run it in a staging namespace. If it is
refused with `no signatures found`, the policy is still looking in the old place. One test pod is
cheaper than discovering this after a routine upgrade.

**Does admission fail closed when it shuts down politely?** `failurePolicy: Fail` only applies
while the webhooks exist. Scale the policy engine to zero, try an unsigned pod, then scale back.
If the pod runs, the enforcement left with the engine. Run at least two replicas, and repeat the
test by deleting one pod during a rollout.

**What can root on one machine read?** On a node, `ls /etc/containerd/ocicrypt/keys/` tells you
whether the image key is there, and the snapshot directory under the containerd data path tells
you whether decrypted layers are. If either is present, root on that machine is inside every
image it has ever run, whatever admission allowed. That is where placement matters: keep the key
off machines that don't need it, keep sensitive pods on their own machines, and remove images you
no longer run. `crictl rmi` is what removed the plain-text model from disk; deleting the pod did
not.

## What comes next

None of this fixes the root user on a machine reading the memory and disk of a running workload.

The pitch for Confidential Containers is that the workload runs in a hardware-isolated guest
that the machine cannot read, and the image key goes to the guest rather than the host. I have
not tested any of that. Part 2 runs it on hardware with SEV-SNP or TDX, which this virtual
machine does not have, and repeats the twelve steps above to see which ones still work.
