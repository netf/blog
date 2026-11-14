#!/usr/bin/env bash
# One command to rebuild and re-measure the lab:   bash scripts/reproduce.sh   (or: make reproduce)
# Installs the OS packages it needs, starts the local registry and canary sink, builds the corpus
# (reusing committed lockfiles), runs the attack, overhead and failure-test suites, and writes
# results/summary.md. The only egress is the registry's read-only npmjs uplink.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
need=()
for p in bwrap:bubblewrap nft:nftables ip:iproute2 bc:bc gcc:gcc; do command -v "${p%%:*}" >/dev/null || need+=("${p##*:}"); done
[ "${#need[@]}" -eq 0 ] || { sudo apt-get update -qq; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"; }
bash scripts/preflight.sh
gcc -O2 -Wall -o landlock/landlock-run landlock/landlock-run.c
sudo bash scripts/netns-up.sh allowlist
bash scripts/registry-up.sh
bash scripts/sink-up.sh
bash scripts/plant-canaries.sh
bash scripts/corpus-build.sh
bash scripts/script-census.sh
N=5 bash scripts/run-attack.sh
WARM_N=5 COLD_N=3 bash scripts/measure-overhead.sh
COMPILE_CACHE=keep OVERHEAD_OUT=overhead-compile-cache.jsonl WARM_N=5 COLD_N=3 bash scripts/measure-overhead.sh
bash scripts/failure-tests.sh
bash scripts/native-controls.sh
node scripts/analyze.cjs > /dev/null
bash scripts/registry-down.sh
sudo ip netns del wormlab 2>/dev/null || true; sudo ip link del veth-wh 2>/dev/null || true
echo "done: results/summary.md"
