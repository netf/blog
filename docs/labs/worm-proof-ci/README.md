# Lab: CI that a Shai-Hulud-style worm can't use

Reproduction kit for the post
[A worm in my CI stole nothing and published nothing. It still wrote to my repo](../../../src/content/blog/worm-proof-ci.md).
Every number in the post comes from `results/`, produced by the scripts here.

## Reproduce

```bash
cd docs/labs/worm-proof-ci
make reproduce        # same as: bash scripts/reproduce.sh   (~35 minutes on 4 vCPU)
```

Needs Linux with Landlock ABI ≥ 4, unprivileged user namespaces and sudo (for the network
namespace and nftables). It installs bubblewrap, nftables, iproute2, bc and Verdaccio if missing,
runs `scripts/preflight.sh`, and ends by writing `results/summary.md`. Nothing is published
outside the local registry.

## What it builds

- **Local registry**: Verdaccio 6.10.7 on the host end of a veth pair (`10.188.0.1:4873`),
  proxying npmjs read-only. Publishing requires an authenticated user; self-registration is off.
- **Worm simulator** `@wormlab/worm-sim` (`worm/worm-sim/`), seeded into the registry as an
  already-compromised dependency. Its `preinstall` and `postinstall` scan for token patterns,
  POST what they find to a hardcoded C2, send it as DNS queries, `npm publish` a bumped copy of
  themselves, and (per test) fork a detached process, write into the checkout and `.git/hooks`,
  and try to write outside it. Only fake `CANARY-*` values exist to be found.
- **Canary sink** (`scripts/sink-server.cjs`): HTTP + DNS listener on the C2 address. A canary
  arriving there is what "stolen" means.
- **Install regimes** (`scripts/stage-install.sh`):
  - `baseline`: plain `npm ci` with the victim's tokens in `$HOME` and the environment.
  - `sandbox`: bubblewrap (empty tmpfs `$HOME`, cleared env, only workspace + npm cache writable)
    inside a network namespace whose nftables policy drops all egress except TCP to the registry.
    Install scripts still run.
  - `landlock`: no root, no namespace. Cleared env, fresh `$HOME`, and `landlock/landlock-run`
    limiting reads, writes and TCP connect (registry port only). Install scripts still run unless
    `--scripts off`.
  - `hardened`: `sandbox` plus `npm ci --ignore-scripts`, then `npm rebuild` for the packages the
    lockfile marks `hasInstallScript` (the per-project allowlist).
- **Publish stage** (`scripts/stage-publish.sh`): the only place the registry credential exists,
  mounted read-only, `--ignore-scripts`, same network jail.
- **Corpus**: 30 real packages (`corpus/corpus.txt`), one project each, pinned by committed
  lockfiles (`corpus/projects/*/package-lock.json`, versions in `corpus/versions.txt`).

## Run order

```bash
gcc -O2 -Wall -o landlock/landlock-run landlock/landlock-run.c
sudo bash scripts/netns-up.sh allowlist   # veth + jail netns + nft allowlist
bash scripts/registry-up.sh               # Verdaccio, publish account, seed the worm
bash scripts/sink-up.sh                   # canary sink
bash scripts/plant-canaries.sh            # victim $HOME and env
bash scripts/corpus-build.sh              # lockfiles (reused if present) + allowlists
bash scripts/script-census.sh             # results/script-census.jsonl (what npm ci really runs)
N=5 bash scripts/run-attack.sh            # results/attack.jsonl
WARM_N=5 COLD_N=3 bash scripts/measure-overhead.sh                                  # results/overhead.jsonl
COMPILE_CACHE=keep OVERHEAD_OUT=overhead-compile-cache.jsonl bash scripts/measure-overhead.sh
bash scripts/failure-tests.sh             # results/failure-tests.jsonl
node scripts/analyze.cjs                  # results/summary.md
```

Don't run two suites at once: they share the network namespace and the sink.

## Results files

| file | contents |
|---|---|
| `results/attack.jsonl` | 4 regimes × 5 runs: secrets found, canaries out per channel, self-publish, checkout writes |
| `results/overhead.jsonl` | 30 projects × 3 regimes × (5 warm + 3 cold), default Node compile cache |
| `results/overhead-compile-cache.jsonl` | the same with a persistent compile cache per regime |
| `results/failure-tests.jsonl` | detached process, HTTP/DNS exfil with a repo secret, native binaries, checkout writes, publish stage |
| `results/script-census.jsonl` | per project: scripts npm ci actually ran vs the lockfile flags, packages with binding.gyp |
| `results/netns-allowlist.nft` | the egress ruleset as loaded |
| `results/summary.md` | everything above, tabulated |

See `environment.md` for the machine, versions and every workaround.
