---
title: 'A worm in my CI stole nothing and published nothing. It still wrote to my repo'
description: 'I ran a harmless Shai-Hulud-style worm through a CI design with sandboxed installs, a token-holding publish stage and an egress allowlist, then installed 30 real projects through it. Theft and self-publish went to 0 of 5. The checkout stayed writable, and Landlock let a secret out over DNS.'
pubDate: 2026-11-14
pillar: platform
tags: ['ci', 'supply-chain', 'security', 'npm', 'sandboxing']
---

One `npm ci` was all it took. The worm read three tokens out of the environment, posted them to its
server, sent them again as DNS lookups, then published two new versions of itself to the registry
using the publish credential that was sitting in `~/.npmrc`. I ran it five times. It did exactly
that five times.

That's the shape of the 2025 Shai-Hulud npm worms. An install script (`postinstall` in the
September wave, `preinstall` in November) ran TruffleHog over the environment it landed in,
including the secrets CI platforms expose, sent what it found out, and used any npm credential to
publish itself into more packages ([CERT VU#534320](https://www.kb.cert.org/vuls/id/534320);
PostHog's [post-mortem](https://github.com/PostHog/post-mortems/blob/main/2025-11-26-shai-hulud-attack.md)).
PostHog's own npm token, by their account, came out of the GitHub secrets available to their CI
runners. The trick wasn't clever. A normal CI job hands every install script your secrets, an open
network and a publish token, all at once.

The standard answer is `--ignore-scripts`, and the standard reply is that it breaks native modules.
So most pipelines keep running scripts with everything in scope. I wanted to know whether a CI
design that splits those three things apart actually stops a worm, and what it costs on real
projects. I built one, wrote a harmless worm that behaves like the real ones (fake canary tokens, a
local registry, a local "C2"), and installed 30 real open-source projects through it. Three
questions:

1. **Does it stop the worm?** Installs sandboxed with no secrets and network only to the registry,
   publishing in a separate stage that holds the token. Does theft and self-propagation go to zero?
2. **What does it cost?** Install time, broken installs, and how many packages need their scripts
   back.
3. **What's left?** Where does a contained worm still get to do something?

I went in expecting theft and spread to drop to zero for about 8% more install time, with the
writable checkout as the hole that remains. The zero held. The 8% was right for the wrong reason,
and the hole turned out to be bigger than writes.

**Same rule as always: if I didn't observe it, it isn't here.** The scripts, raw JSONL and a
one-command reproduce are in
[`docs/labs/worm-proof-ci/`](https://github.com/netf/blog/tree/main/docs/labs/worm-proof-ci).
Every secret in the lab is a fake `CANARY-...` string, and nothing was published anywhere but a
local registry.

## The short version

- **A plain `npm ci` gives the worm everything.** It found 4 secrets, got all 3 canary tokens out
  over both HTTP and DNS, and published 2 new versions of itself. 5 runs out of 5.
- **Sandboxing the install took that to zero, with the worm's code still running.** In a
  bubblewrap sandbox inside a network namespace that only reaches the registry, and in a Landlock
  variant that needs no root, the worm found 0 secrets, got 0 out and published 0 versions in 5/5
  runs each. Its publish attempts failed with `ENEEDAUTH`: the registry was reachable, but the token
  lived in another stage. With `--ignore-scripts` added, the worm never ran at all.
- **The cost out of the box was 68 ms per install (median), and almost none of it was the
  sandbox.** It was npm losing Node's compile cache in a fresh `/tmp`. With a persistent compile
  cache, the median overhead was 5 ms. The 7 projects that rebuild allowlisted packages paid about
  170 ms each, which made the corpus as a whole 10.8% slower warm and 4.3% slower cold. 240 of 240
  installs succeeded in every regime.
- **The allowlist barely matters for function, and the lockfile gets it wrong.** npm actually ran
  install scripts in 6 of 30 projects. All 7 script-bearing packages I exercised worked without
  their scripts, because they ship prebuilt binaries. npm's `hasInstallScript` flag missed one
  package that does run a script, better-sqlite3. Letting that script run inside the jail broke
  the install until node-gyp was pointed at local headers.
- **The checkout is the hole, in both directions.** Every regime where the worm ran let it plant a
  git hook and a `core.fsmonitor` command in `.git/config`. A later `git status` and `git commit`
  ran both. A secret committed in the repo's `.env` was readable in both sandboxes. nftables kept it
  in. Landlock let it out over DNS, because Landlock doesn't filter UDP.

## Who holds what

The design takes the three things a worm needs and puts them in different places.

```text
                 INSTALL stage: runs dependency code, holds nothing
  +-----------------------------------------------------------------------+
  | bubblewrap                              | network namespace           |
  |   $HOME = empty tmpfs                   |   nftables output policy:   |
  |   environment cleared                   |   drop everything except    |
  |   writable: the checkout + npm cache    |   TCP to the registry       |
  +-----------------------------------------------------------------------+
        | npm ci --ignore-scripts                 x  worm's C2 (HTTP, DNS)
        | npm rebuild <allowlisted packages>      x  npm publish: ENEEDAUTH, no token
        v
  [ registry proxy ]  <-- npm publish --ignore-scripts --
   Verdaccio, publish                                     |
   needs an account          PUBLISH stage: holds the token, runs no dependency code
```

A worm that lands in the install stage gets:

- **Nothing to steal.** `$HOME` is an empty tmpfs, so there's no `~/.npmrc`, no
  `~/.aws/credentials`, no `~/.config/gh`. The environment is cleared down to `PATH` and `HOME`, so
  there's no `NPM_TOKEN` or `GITHUB_TOKEN` in `process.env`.
- **Nowhere to send anything.** The install runs in its own network namespace whose nftables output
  chain drops everything except TCP to the registry. That includes UDP, so it includes DNS. The
  registry is addressed by IP, so the install never needs a resolver.
- **No way to publish.** The registry is reachable, because installs need it, but publishing needs
  an authenticated account and the install stage has no credential. The publish stage has it,
  mounted read-only, and runs `npm publish --ignore-scripts`.
- **Usually, no chance to run.** `npm ci --ignore-scripts`, then `npm rebuild` for the packages you
  allow by name.

The Landlock variant does the same job without root or namespaces. A 74-line C wrapper
([`landlock-run.c`](https://github.com/netf/blog/blob/main/docs/labs/worm-proof-ci/landlock/landlock-run.c))
lets the install read system directories, the Node install and the checkout, write only the
checkout, the npm cache and a fresh temp dir, and `connect()` over TCP only to the registry's port.
Landlock can't filter by address, only by port, and it has no UDP rules at all. That last part
comes back later.

## The lab

One KVM guest: Ubuntu 24.04.5, kernel 6.12.113, 4 vCPU, 15 GiB, Landlock ABI 6, unprivileged user
namespaces enabled. bubblewrap 0.9.0, nftables 1.0.9, Node 22.23.4, npm 10.9.9, and Verdaccio
6.10.7 as the registry, proxying npmjs read-only so the corpus installs real packages. Every
publish, the worm's and the legitimate one, goes to that local Verdaccio.

The worm is an npm package, `@wormlab/worm-sim`, published into the local registry as an
already-compromised dependency of a small victim project. Its `preinstall` and `postinstall` do
what the real ones did: a TruffleHog-style scan of the environment, the usual credential files and
the checkout; an HTTP POST and a DNS query per secret to a hardcoded address; and an `npm publish`
of a freshly versioned copy of itself. Depending on the test, it also forks a detached background
process, writes into the checkout, `.git/hooks` and `.git/config`, and tries to write next to the
checkout.

"Stolen" means a canary value arrived at the sink, a small HTTP and DNS listener at the worm's C2
address. "Self-published" means a new `99.x` version appeared in the registry. Both are observed
from outside the worm.

Four regimes:

| regime | what runs | the worm's script runs? |
|---|---|---|
| `baseline` | plain `npm ci`, victim's `$HOME` and env, publish credential in `~/.npmrc` | yes |
| `sandbox` | bubblewrap + network namespace with the egress allowlist | yes |
| `landlock` | Landlock wrapper + cleared env, no root | yes |
| `hardened` | `sandbox` + `--ignore-scripts` + `npm rebuild` of allowlisted packages | no |

`sandbox` and `landlock` deliberately leave scripts on. They answer "what if a package you allowed
is the compromised one?"

## Does it stop the worm?

Yes. Five runs per regime:

| regime | secrets found | canaries out via HTTP | via DNS | runs that self-published | checkout write | git hook |
|---|---|---|---|---|---|---|
| baseline | 4 | 3/3 (5/5) | 3/3 (5/5) | 5/5 | 5/5 | 5/5 |
| sandbox | **0** | **0 (0/5)** | **0 (0/5)** | **0/5** | 5/5 | 5/5 |
| landlock | **0** | **0 (0/5)** | **0 (0/5)** | **0/5** | 5/5 | 5/5 |
| hardened | worm never ran | 0 (0/5) | 0 (0/5) | 0/5 | 0/5 | 0/5 |

In the baseline the worm finds `GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY` and `NPM_TOKEN` in the
environment plus the AWS key id in `~/.aws/credentials`, sends them out both ways, and publishes
itself twice per install, once from each hook.

In `sandbox` and `landlock` the same code runs and comes up empty. The scan finds nothing because
there is nothing in an empty home and a cleared environment. In the namespace the HTTP POST times
out and the DNS packet fails to send with `EPERM`. Under Landlock the POST fails with `EACCES`.
With nothing found, there was nothing to put in a DNS query. The publish fails like this:

```text
npm error code ENEEDAUTH
npm error need auth This command requires you to be logged in to http://10.188.0.1:4873/
```

That error is the design working. The install can talk to the registry because it has to. It
can't publish because the credential was never in the room. A worm inherits whatever the install
step can do, and in this design publishing isn't on that list.

For contrast, the publish stage published a test package to the same registry with the same
sandbox and network policy. Its `prepublishOnly` script didn't run, because of `--ignore-scripts`.

Two failure tests belong here, because they target the obvious ways around this kind of
containment.

**A detached background process.** The worm forks a child that keeps POSTing to its C2 once a
second, so killing the install doesn't kill it. I measured only what happened after the install
command had returned:

| regime | worm processes still alive | hits at the C2 after exit |
|---|---|---|
| baseline | 2 | 16 |
| sandbox | 0 | 0 |
| landlock | 2 | 0 |

bubblewrap's PID namespace takes the children down with it when the sandbox exits. Landlock doesn't
own the process lifetime, so both children survived. They just couldn't open a TCP connection to
anything but the registry port.

**DNS exfiltration.** Blocked in the namespace, because the nftables policy drops UDP and the
install doesn't need a resolver. Under Landlock it went through. More on that in the section on
what's left.

## What does it cost?

This is where my hypothesis looked wrong at first. Across 30 projects, 5 warm and 3 cold installs
each per regime, interleaved, the sandboxes looked like a flat tax:

| warm cache, median of 5 | baseline | hardened | landlock |
|---|---|---|---|
| chalk (1 package) | 0.190 s | 0.257 s | 0.264 s |
| express (65) | 0.314 s | 0.393 s | 0.394 s |
| webpack (63) | 0.634 s | 0.711 s | 0.715 s |
| jest (309) | 1.047 s | 1.360 s | 1.389 s |

The median project paid 68 ms (1.28x) in the bubblewrap sandbox and 78 ms (1.32x) under Landlock.
Summed over the corpus, that's 31% and 36% slower warm, and 19% and 18% cold. It looked like a fixed
startup cost, and I almost wrote it up that way.

Then the Landlock numbers stopped making sense. Landlock has no namespace to create, no `sudo`, no
mounts. A few `landlock_add_rule` calls should cost microseconds, not 70 ms. `strace` showed what
was going on. npm on Node 22 keeps a compile cache in `/tmp/node-compile-cache`. Under Landlock,
`npm --version` alone made 138 `openat()` calls into that directory, and all of them were denied.
In the bubblewrap sandbox `/tmp` is a fresh tmpfs, so the cache was always empty. Either way, npm
recompiled its own JavaScript on every install. The baseline, running on the host, had a warm
cache. `npm --version` takes 64 ms with a cold compile cache and 53 ms with a warm one. `npm ci`
loads far more of npm than `--version` does, and the second corpus run shows what that adds up to.

So I ran the whole corpus again, giving every regime, baseline included, a compile cache that
persists inside its own npm cache directory (`NODE_COMPILE_CACHE`):

| warm cache, median of 5 | baseline | hardened | landlock |
|---|---|---|---|
| chalk | 0.181 s | 0.185 s | 0.182 s |
| express | 0.297 s | 0.303 s | 0.299 s |
| webpack | 0.629 s | 0.633 s | 0.631 s |
| jest | 1.037 s | 1.225 s | 1.234 s |
| esbuild | 0.315 s | 0.481 s | 0.487 s |
| bcrypt | 0.275 s | 0.444 s | 0.450 s |
| better-sqlite3 | 0.531 s | 0.341 s | 0.336 s |

The median project now pays 5 ms in bubblewrap and 1 ms under Landlock. For the 23 projects with
nothing to rebuild, the bubblewrap sandbox costs 4 ms and Landlock costs nothing measurable.

What's left is the 7 projects whose lockfile flags an install script. The hardened path runs
`npm ci --ignore-scripts` and then a second `npm rebuild` for the allowlisted packages. That second
npm process is about 170 ms: 1.53x the baseline warm and 1.30x cold. It's what turns "free" into
10.8% summed over the corpus warm and 4.3% cold. So the 8% I guessed lands in the right range,
but the cost is one extra npm invocation on a quarter of the projects, not a tax on every install.
better-sqlite3 got faster sandboxed, for a reason that comes up in the next section.

Install success was 240/240 in every regime, in both datasets.

These installs are small. With a warm registry and npm cache, most finish in under a second, so
fixed costs show up as large percentages. In absolute time, the extra `npm rebuild` adds about
170 ms to a job, and the sandbox itself adds a few milliseconds.

## How many packages need their scripts back?

I expected about 80% of projects to need no allowlist. I counted that two ways.

**What the lockfile says.** npm records `hasInstallScript: true` for packages with a `preinstall`,
`install` or `postinstall`. 7 of 30 projects have at least one, from 6 distinct packages: esbuild,
bcrypt, `@swc/core`, core-js, `@parcel/watcher` (via jest) and fsevents (via rollup and vite).

**What npm actually ran.** I installed every project with scripts on and `--foreground-scripts`,
and parsed npm's `> package@version install` banners. Scripts ran in 6 of 30 projects, so 80% need
none. The two counts disagree on two packages:

- **fsevents** is flagged but never runs on Linux. It's a macOS-only optional dependency and never
  gets installed. rollup and vite paid the extra `npm rebuild` for nothing.
- **better-sqlite3 runs a script nobody flagged.** Its `package.json` has no install script and
  sets `gypfile: false`, and its lockfile entry has no `hasInstallScript`. Under `npm ci`, npm runs
  `node-gyp rebuild` for it anyway. A plain `npm install` without a lockfile does not. My reading
  of npm 10.9.9's code is that `npm ci` builds its view of the package from the lockfile, which
  drops `gypfile`, so the opt-out never reaches the check that looks for a `binding.gyp`. That's
  inference from the source. The behaviour itself I reproduced. It's also why better-sqlite3's
  baseline is the slow one: it was the only regime running node-gyp.

So an allowlist built from `hasInstallScript` is wrong in both directions. If you want the real
list, install with scripts on and `--foreground-scripts` once, and read what ran.

Then I checked whether any of those scripts matter. I installed esbuild, bcrypt, `@swc/core`,
sharp, better-sqlite3, core-js and jest with `--ignore-scripts` and no allowlist, and made each one
do real work: an esbuild transform, a bcrypt hash and compare, a `@swc/core` transform, a sharp PNG
encode, a better-sqlite3 insert, a core-js polyfill, and an `@parcel/watcher` subscription that
has to see a file change.

All seven worked without their scripts.

That only means something if the test can fail, so I ran a negative control for each native
package: install with `--ignore-scripts`, pass the smoke test, delete the prebuilt binary the
package actually loads, run it again. Every one then failed. sharp needed two deletions, because
when its native binary was gone it quietly fell back to a WebAssembly build. The binaries arrive
as platform-specific optional dependencies (`@esbuild/linux-x64`, `@img/sharp-linux-x64`,
`@parcel/watcher-linux-x64-glibc`) or as bundled `prebuilds/`, which npm installs as files, not
scripts. I read the scripts that remain. esbuild's and `@swc/core`'s check that the prebuilt
binary loads and fetch a fallback if it doesn't. bcrypt's and better-sqlite3's build from source
only if no prebuild matches. `@parcel/watcher`'s builds only when you ask for a source build.
core-js's prints a thank-you banner. On a platform with prebuilds, none of them has work to do.

**What happens when you do let one run.** better-sqlite3's implicit `node-gyp rebuild` is designed
to be a no-op when a prebuild exists. Its `binding.gyp` checks for one first. But node-gyp
downloads the Node headers from nodejs.org before it gets that far. Inside the jail, that's a
blocked host:

| regime | better-sqlite3 script | Node headers | install |
|---|---|---|---|
| sandbox | runs (scripts on) | fetched from nodejs.org | **fails**: `getaddrinfo EAI_AGAIN nodejs.org` |
| hardened | allowlisted | fetched from nodejs.org | **fails**, same |
| hardened | allowlisted | `npm_config_nodedir` = the local Node install | succeeds |
| landlock | allowlisted | fetched from nodejs.org | **fails**, same header download |
| landlock | allowlisted | local | succeeds |

That's the "packages that download binaries" failure in its usual form. The install script itself
is harmless and does nothing, but it phones home first. Pointing node-gyp at the headers already
on disk fixes it without opening the egress policy.

## What's left: the checkout

Back to the first table. Wherever the worm's code ran, two columns stayed green for it: a file in
the checkout and a git hook, 5/5 in every regime.

The install has to write to the checkout, so the checkout is writable, and so is `.git` inside it.
The worm finds the checkout root through `INIT_CWD`, which npm sets to the directory the install
was started in, and leaves three things:

```text
WORM_WAS_HERE.txt
.git/hooks/pre-commit                 # runs on the next commit in this checkout
.git/config:  [core] fsmonitor = ...  # a command git runs on the next `git status`
```

In the lab, the hook and the fsmonitor command only leave marker files. A real worm would run its
payload there, outside the install sandbox, in whatever later step touches git. I played that later
step: after each install, a plain `git status` and `git commit` in the checkout, as a lint or
version-bump job would run them.

| regime | wrote hook + git config | later `git status` / `git commit` ran them | same, with git config overridden | wrote next to the checkout |
|---|---|---|---|---|
| baseline | yes | hook: yes, fsmonitor: yes | no, no | yes |
| sandbox | yes | hook: yes, fsmonitor: yes | no, no | no |
| landlock | yes | hook: yes, fsmonitor: yes | no, no | no |

The fsmonitor line is the nasty one. It means the obvious defence, "check the tree with
`git status` before trusting it", runs the worm's command. `git status` also doesn't show changes
under `.git/hooks`, so it wouldn't spot the hook anyway. What worked was overriding both settings
from the environment for every later git command, which beats anything the worm writes into the
repository's config (the overrides are in "What I'd do").

Nothing in either sandbox can tell these writes apart from an install writing `node_modules`. What
the sandboxes did stop was writing next to the checkout. In the baseline the worm created a file in
the parent directory. In both sandboxes nothing appeared on the host. In the bubblewrap case the
worm thought it had succeeded, because it wrote into bubblewrap's throwaway root.

The checkout is also readable, and I hadn't planned for that. I committed a `.env` with a canary
database URL into the victim project, the kind of file that ends up in repos, and ran the scan and
exfiltration again:

| regime | secrets found | repo secret out via HTTP | via DNS |
|---|---|---|---|
| baseline | 5 | yes | yes |
| sandbox | 1 (the repo secret) | no | no |
| landlock | 1 (the repo secret) | no | **yes** |

Both sandboxes hid every credential that was *given* to the job. Neither can hide what's in the
repository, because the install needs to read the repository. After that it comes down to egress.
nftables in the namespace dropped the DNS query like everything else. Landlock's network rules only
cover TCP `bind` and `connect`, so the worm's UDP packet to its "resolver" got out of the sandbox
and reached the sink with the secret in the hostname, twice per install.

So if you go the no-root Landlock route, you still need something that controls UDP. That means a
network namespace, a firewall rule for the runner's user, or a runner whose network already only
reaches the proxy.

## What I'd do

In order, because the order is roughly how much each step buys.

**1. Take the token out of the install job.** This is the change that stops propagation, and it
costs nothing. In GitHub Actions terms it's two jobs, with the secret only in the second. I ran the
same split as shell stages on the lab VM, not on GitHub's runners:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false        # don't keep the job's GitHub token around for later steps
      - run: ./ci/sandboxed-install.sh      # the wrapper below; no secrets in this job
      - run: npm test

  publish:
    needs: build
    if: startsWith(github.ref, 'refs/tags/')
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - uses: actions/setup-node@v7
        with:
          registry-url: https://registry.npmjs.org
          package-manager-cache: false      # no dependency cache in the job that holds the token
      - run: npm publish --ignore-scripts   # no install step: nothing from node_modules runs here
        env:
          NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}
```

`package-manager-cache: false` is what setup-node's README recommends for workflows with
privileged access.

**2. Run the install with nothing to steal and nowhere to send it.** This is the measured wrapper,
trimmed for a fresh runner. It needs root for the namespace and unprivileged user namespaces for
bubblewrap, and `scripts/preflight.sh` in the lab checks both. `scripts/test-post-wrapper.sh`
extracts this exact block from the post and runs it. It installed express, and esbuild with an
allowlisted rebuild, with exit code 0. From inside the jail the registry answered, the C2 port and
UDP to 1.1.1.1 were blocked, and `$HOME` and the token variables were empty.

```bash
#!/usr/bin/env bash
set -euo pipefail
# A registry proxy (Verdaccio, a pull-through cache) listening on this runner at REGISTRY_IP;
# the jail's only route is to the runner's end of the veth pair.
REGISTRY_IP=10.188.0.1 REGISTRY_PORT=4873
NODE_DIR="$(dirname "$(dirname "$(command -v npm)")")"
CACHE="$PWD/.npm-cache"; mkdir -p "$CACHE"

# An egress jail that reaches the registry and nothing else.
sudo ip netns add ci
sudo ip link add veth-h type veth peer name veth-c
sudo ip link set veth-c netns ci
sudo ip addr add "$REGISTRY_IP/24" dev veth-h && sudo ip link set veth-h up
sudo ip -n ci addr add 10.188.0.2/24 dev veth-c && sudo ip -n ci link set veth-c up
sudo ip -n ci link set lo up && sudo ip -n ci route add default via "$REGISTRY_IP"
sudo ip netns exec ci nft -f - <<EOF
table inet egress {
  chain output {
    type filter hook output priority 0; policy drop;
    oif "lo" accept
    ct state established,related accept
    ip daddr $REGISTRY_IP tcp dport $REGISTRY_PORT accept
  }
}
EOF

# Empty home, cleared environment, only the checkout and the cache writable.
sandbox() {
  sudo ip netns exec ci setpriv --reuid "$(id -u)" --regid "$(id -g)" --clear-groups \
    bwrap --unshare-user --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup \
      --die-with-parent --new-session \
      --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /sbin /sbin \
      --ro-bind-try /lib /lib --ro-bind-try /lib64 /lib64 --ro-bind /etc /etc \
      --ro-bind "$NODE_DIR" "$NODE_DIR" --proc /proc --dev /dev --tmpfs /tmp --tmpfs /home/ci \
      --bind "$PWD" "$PWD" --bind "$CACHE" "$CACHE" --chdir "$PWD" --clearenv \
      --setenv HOME /home/ci --setenv PATH "$NODE_DIR/bin:/usr/bin:/bin" \
      --setenv NODE_COMPILE_CACHE "$CACHE/node-compile-cache" \
      --setenv npm_config_nodedir "$NODE_DIR" \
      "$@"
}

sandbox npm ci --ignore-scripts --no-audit --no-fund \
  --registry "http://$REGISTRY_IP:$REGISTRY_PORT" --cache "$CACHE"
if [ -s ci/allowlist.txt ]; then sandbox npm rebuild $(cat ci/allowlist.txt); fi
```

`NODE_COMPILE_CACHE` is the line that took the sandbox's cost from 68 ms to 5 ms.
`npm_config_nodedir` is what lets an allowlisted node-gyp package build without calling
nodejs.org. The compile cache now lives in a directory the install stage writes, so it's
dependency-writable state like the npm cache next to it. Don't share either with the publish
stage.

**3. Build the allowlist from what runs, not from the lockfile.** Do it once, outside the jail,
with scripts on:

```bash
npm ci --foreground-scripts 2>&1 \
  | sed -nE 's/^> (.+)@[^ ]+ (preinstall|install|postinstall)$/\1/p' | sort -u
```

Then try the build without each entry. For this corpus the right allowlist turned out to be empty.

**4. Treat the checkout as untrusted after the install.** Don't set the git settings you depend on
in `.git/config`, because the install can rewrite that file. Override them from the environment in
every later step, which takes precedence over repository config:

```bash
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
export GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false
git status --porcelain     # now safe to run; shows stray files like WORM_WAS_HERE.txt
```

In the lab that stopped both the planted hook and the fsmonitor command in all three regimes. It
only covers the two settings I tested. Other config keys that name commands deserve the same
treatment, and the safer habit is to run later git steps in a fresh checkout. `git status` won't
show anything under `.git`, so don't rely on it to find a planted hook. Keep secrets out of the
repository too: the sandbox can't hide them from code that has to read the repository. This is the
step I'm least sure is complete.

## What this lab tells you

- **Take the publish token out of the install stage; it's the cheapest change and it stops the
  spread.** The worm reached the registry in every regime and couldn't publish in any of them,
  because the credential only existed in a stage that runs no dependency code.
- **You don't have to stop the code running to stop it stealing.** With an empty home, a cleared
  environment and a registry-only egress policy, a compromised install script found 0 of 4 secrets
  and got nothing out over HTTP or DNS. That matters because the package you allowlisted might be
  the compromised one.
- **`--ignore-scripts` breaks much less than its reputation.** npm ran scripts in 6 of 30 projects,
  and all 7 script-bearing packages I exercised worked without them, verified by controls that fail
  when the prebuilt binary is removed.
- **Don't trust `hasInstallScript` as your allowlist.** It flagged a macOS-only package that never
  installs on Linux and missed better-sqlite3, which `npm ci` builds with node-gyp anyway. Read
  what actually runs.
- **Most of the measured sandbox cost was a cold Node compile cache.** Give the sandbox a
  persistent `NODE_COMPILE_CACHE` and the median per-install cost went from 68 ms to 5 ms. The real
  remaining cost is the extra `npm rebuild` process for allowlisted packages, about 170 ms.
- **The checkout is the hole, for writes and for reads.** A contained worm still planted a git hook
  and a `core.fsmonitor` command every time, and a later plain `git status` and `git commit` ran
  both. Overriding those settings from the environment stopped both. It also still found a secret
  committed to the repo.
- **Landlock alone doesn't stop DNS exfiltration.** It has no UDP rules, and the repo secret left
  over DNS. Its TCP restrictions held, and so did its filesystem rules. bubblewrap in a network
  namespace stopped both and also killed the worm's background processes on exit. Landlock left
  them running.

If I had to change one thing on Monday, I'd move `NPM_TOKEN` out of every job that runs `npm ci`.
That one change is the difference between a worm that steals and a worm that spreads.

What I still don't have is a good answer for the checkout. Detecting a planted hook after the fact
is easy. Running an install that can write `node_modules` but can't touch anything else in the
repository would need a split mount layout that npm doesn't expect. That's the next thing I want
to try.

## Reproduce it

```bash
git clone https://github.com/netf/blog && cd blog/docs/labs/worm-proof-ci
make reproduce     # or: bash scripts/reproduce.sh. Ubuntu 24.04, 4 vCPU, sudo, about 35 minutes
```

It runs the preflight first and stops if Landlock, user namespaces or the netns/nftables pieces are
missing. It installs bubblewrap, nftables and Verdaccio if needed, reuses the committed lockfiles,
runs every suite, and regenerates `results/summary.md`. Nothing is published anywhere but the local
registry. Corrections are welcome, and if you can get a canary out of the `sandbox` row, I'd like
to know how.

## Appendix A: Methodology

**Scope.** One KVM guest, npm only. CI stages are shell scripts run on the host the way a
self-hosted runner runs job steps. There's no Docker or `act` in the loop, because running
bubblewrap's user-namespace sandbox inside a container would need `--privileged` and change what's
measured. The GitHub Actions file above is the same split written as a workflow. I didn't run it on
GitHub's runners. The registry is a local Verdaccio proxying npmjs, so "the registry is reachable"
means the proxy, not the internet. The worm models the observable behaviour of the 2025 worms, not
any specific sample. bubblewrap is Ubuntu's 0.9.0, not the 0.13.1 I'd originally pinned. I built the
lab on one VM and lost its working tree when the VM was recycled before I'd pushed. Every number
here comes from a second VM of the same shape, kernel 6.12.113. Every attack and failure-test
outcome measured on both VMs matched (the Landlock regime and the later tests exist only on the
second). A `make reproduce` from a fresh clone on the second VM exited cleanly in
about 32 minutes. It matched every attack, failure-test, census and control outcome. Its overhead
medians were within 0.02x of the ones above. Its summed cold overhead with the compile cache was
8.2% for bubblewrap and 3.9% for Landlock, against 4.3% and 1.1% here, so read the cold sums as
"single digits" rather than as precise figures.

**Attack.** 5 runs per regime. Before each run the victim project is recreated and the sink
restarted with an empty log. Canaries are counted as distinct `CANARY-*` values in the sink's log
per channel. Self-publish is the change in the number of `99.x` versions of the worm in the registry
across the run. The worm's own report is only used for the number of secrets its scan found and the
npm error code of its publish.

**Overhead.** 30 projects, each one dependency on the latest version on 2026-11-14 (pinned by the
committed lockfiles), installed with `npm ci`. For each project and regime: one priming install
(not recorded), 5 warm installs reusing the npm cache, and 3 cold installs with the npm cache wiped
first. The registry stays warm, as a CI proxy would be. The three regimes are interleaved within
each round. `hardened` and `landlock` both use `--ignore-scripts` plus `npm rebuild` of the
packages flagged `hasInstallScript`. Wall time covers both npm invocations. Two complete datasets
were collected: the default, and one with `NODE_COMPILE_CACHE` set inside each regime's own cache
directory, wiped along with it on cold runs.

**Script census.** Each project installed once with scripts on, on the host, with
`--foreground-scripts`. Ran-script lists come from npm's lifecycle banners.

**Native-binary checks.** Install under `hardened` with and without the allowlist, then run the
smoke test on the host against the installed tree. Each negative control deletes the package's
prebuilt binary and re-runs the same test.

**Failure tests.** Each test runs once per regime. While I added tests, the whole suite ran seven
times, plus once more in the fresh-clone reproduce, and every outcome that was repeated came out the
same. The committed results come from the final run, with worm v1.0.1. That version added the
`.git/config` write and replaced the hook's payload with a marker; the attack table was re-run on it
too. Detached processes are counted with `pgrep` one second after the install returns, and C2 hits
over the following seven seconds. The "later step" in the checkout test is `git status --porcelain`
then `git commit --allow-empty`, run on the host, once plain and once with `GIT_CONFIG_COUNT`
overrides for `core.hooksPath` and `core.fsmonitor`.

## Appendix B: Versions and evidence

| | |
|---|---|
| Host | Ubuntu 24.04.5, kernel 6.12.113+, 4 vCPU, 15 GiB, KVM, cgroup v2 |
| Landlock | ABI 6 |
| bubblewrap / nftables / iproute2 | 0.9.0 / 1.0.9 / 6.1.0 |
| Node / npm | 22.23.4 / 10.9.9 |
| Verdaccio | 6.10.7 |
| Corpus | `corpus/versions.txt` (for example express 5.3.0, webpack 5.112.2, jest 30.5.2, esbuild 0.28.2, better-sqlite3 13.2.0) |

Raw results in the lab directory: `results/attack.jsonl`, `results/overhead.jsonl`,
`results/overhead-compile-cache.jsonl`, `results/script-census.jsonl`,
`results/failure-tests.jsonl`, `results/native-controls.jsonl`,
`results/compile-cache-evidence.txt`, `results/gyp-ci-vs-install.txt`, `results/post-wrapper-check.txt`, one worm report per regime
(`results/sample-worm-report-*.jsonl`), the fresh-clone run (`results/reproduce-check/`), the loaded
nftables ruleset, and `results/summary.md` with every table above and the full per-project ones.
