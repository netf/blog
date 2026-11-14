# Environment preflight: worm-proof-ci

The lab ran on two VMs. The first (2026-10-22) is where the design was built and debugged. Its
working tree was lost when that VM was recycled before the branch was pushed, so every committed
number comes from the second VM (2026-11-14), where the lab was rebuilt and every suite re-run.
The two runs agreed on every attack and failure-test outcome; overhead numbers below are from VM 2
only. `scripts/preflight.sh` prints this table on any machine.

## VM 2 (all committed results)

| What | Value | How checked |
|---|---|---|
| CPU | 4 vCPU | `nproc` |
| Memory | 15 GiB total, ~4.9 GiB available at start | `free -h` |
| Disk | `/` 254 GB, 247 GB free | `df -h /` |
| Virtualisation | `kvm` (a VM; no nested virtualisation, not a container) | `systemd-detect-virt` |
| OS / kernel | Ubuntu 24.04.5, 6.12.113+ | `/etc/os-release`, `uname -r` |
| cgroups | v2 (`cgroup2fs`) | `stat -fc %T /sys/fs/cgroup` |
| Landlock | active, **ABI 6** | LSM list `capability,landlock,selinux,bpf`; `landlock_create_ruleset(NULL,0,VERSION)` |
| Unprivileged user namespaces | usable | `unshare -Urn true` as uid 1000 |
| Network namespaces + nftables | usable (with sudo) | `ip netns add`, `nft add table` inside it |
| Outbound | `registry.npmjs.org` HTTP 200 | `curl` (used only by Verdaccio's read-only uplink) |

| Tool | Version | Source |
|---|---|---|
| Node.js / npm | v22.23.4 / 10.9.9 | pre-installed (nvm) |
| bubblewrap | 0.9.0 | `apt-get install bubblewrap` |
| nftables | 1.0.9 | `apt-get install nftables` |
| iproute2 | 6.1.0 | `apt-get install iproute2` |
| gcc | 13.3.0 | pre-installed (builds `landlock/landlock-run.c`) |
| OpenSSL | 3.0.13 | pre-installed (htpasswd hash) |
| Verdaccio | 6.10.7 | npm, into `registry/` (gitignored) |

VM 1 was the same image class (4 vCPU, 15 GiB, KVM, Ubuntu 24.04.5) on kernel 6.12.94+, with the
same tool versions.

## Missing pieces, substitutions and workarounds

1. **bubblewrap 0.9.0, not the pitch's pinned v0.13.1.** Ubuntu 24.04 ships 0.9.0 and I did not
   build 0.13.1 from source. Every flag the lab uses (`--unshare-*`, `--die-with-parent`,
   `--new-session`, `--clearenv`, `--tmpfs`, `--ro-bind-try`) exists in 0.9.0.
2. **Docker, Kind and a CI runner (`act` / GitLab runner) are not used.** Docker is not installed
   on these VMs. More importantly, running bubblewrap's user-namespace sandbox inside a container
   would need `--privileged`, which changes what is being measured. CI stages are therefore shell
   scripts run directly on the host, the way a self-hosted runner executes job steps. The post's
   methodology says so.
3. **Verdaccio instead of the public registry.** The registry proxies npmjs read-only so the corpus
   installs real packages, but every publish (the worm's and the legitimate one) goes to the local
   instance. Self-registration is disabled (`max_users: -1`); the publish account authenticates with
   HTTP Basic against an htpasswd file because Verdaccio's token-minting endpoint is disabled along
   with registration.
4. **Verdaccio uplink circuit breaker.** With default `max_fails`, a burst of parallel metadata
   requests while locking the corpus tripped the uplink and Verdaccio returned 404 for uncached
   packages (23 of 30 failed on VM 1). `config/verdaccio.yaml` raises `max_fails` and lowers
   `fail_timeout`.
5. **Root for the network jail.** Creating the netns and loading nft rules needs sudo, as a CI
   runner would have. The install itself runs as uid 1000 (`setpriv` drops privileges before
   bubblewrap). The Landlock regime needs no root at all.
6. **The workspace `package.json` sets `"type": "module"`**, so standalone `.js` helpers in the lab
   would be parsed as ESM. Helpers are `.cjs`; the worm package has its own `package.json`.

## Safety invariants

- Every planted secret is a literal `CANARY-*` string or the credential for the local registry.
  No real credential is ever written to disk or put in the environment.
- The worm's C2 (`worm/worm-sim/c2.json`) is the lab's veth address. It has no way to reach a
  public host.
- Nothing is published anywhere except the local Verdaccio.
