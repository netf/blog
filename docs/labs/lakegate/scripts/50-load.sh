#!/usr/bin/env bash
# Polaris C under 50 concurrent jobs: burst and 120 s loop, with and without credential vending.
# Samples polaris-c CPU every 2 s and counts STS AssumeRole calls in each window.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p results/load
for mode in plain vended; do
  for shape in burst loop; do
    start=$(date -u +%FT%T.%3NZ)
    ( while true; do docker stats --no-stream --format "$(date -u +%T)\t{{.CPUPerc}}\t{{.MemUsage}}" lakegate-polaris-c-1; sleep 1; done ) > results/load/cpu-$mode-$shape.tsv &
    S=$!
    docker compose exec -T -e PYTHONPATH=/lab/kit py python kit/loadtest.py $mode $shape 120
    kill $S; sleep 3
    end=$(date -u +%FT%T.%3NZ)
    python3 - "$start" "$end" "$mode-$shape" <<'E'
import json, sys
s, e, name = sys.argv[1:]
n = 0
for l in open("results/audit/audit.jsonl"):
    if '"AssumeRole"' not in l: continue
    r = json.loads(l)
    if s[:23] <= r["time"][:23] <= e[:23] and r["requestHost"].startswith("sts"): n += 1
cpu = [float(l.split("\t")[1].rstrip("%")) for l in open(f"results/load/cpu-{name}.tsv") if l.strip()]
out = json.load(open(f"results/load/{name}.json"))
out.update({"window": [s, e], "sts_assume_role_calls": n,
            "polaris_cpu_pct_max": max(cpu) if cpu else None, "polaris_cpu_pct_mean": round(sum(cpu) / len(cpu), 1) if cpu else None,
            "cpu_samples": len(cpu)})
json.dump(out, open(f"results/load/{name}.json", "w"), indent=2)
print(name, json.dumps({k: out[k] for k in ("sts_assume_role_calls", "polaris_cpu_pct_max", "polaris_cpu_pct_mean")}))
E
    sleep 20
  done
done
