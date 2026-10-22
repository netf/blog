#!/usr/bin/env bash
# One command, start to finish:  ./reproduce.sh      (about 1.5 hours on 4 vCPUs)
# Scale down with:              N_CUSTOMERS=1000000 N_ORDERS=5000000 ./reproduce.sh
set -euo pipefail
cd "$(dirname "$0")"
N_CUSTOMERS=${N_CUSTOMERS:-10000000}
N_ORDERS=${N_ORDERS:-50000000}
PY=../.venv/bin/python

./scripts/00-preflight.sh
./scripts/01-setup.sh
mkdir -p results/{generate,ingest,sizes,join,rotation,attack,frequency,reid}

cd scripts
$PY 02-generate.py "$N_CUSTOMERS" "$N_ORDERS" | tee ../results/generate/generate.log
$PY keys.py
./03-bench-ingest.sh 5
$PY sizes.py > ../results/sizes/sizes.json
rm -f ../data/warehouse/*.duckdb ../data/warehouse/*.duckdb.wal
$PY bench_join.py 3 5 > ../results/join/runs.jsonl
./04-rotate.sh 3
for r in 1 2 3; do
  $PY attack_dictionary.py 10000000 > "../results/attack/dictionary-run$r.json"
  $PY attack_phone.py "$r" > "../results/attack/phone-run$r.json"
done
$PY frequency.py 3 > ../results/frequency/frequency.json
$PY test_reid.py 3 > ../results/reid/reid.json
$PY summarize.py > ../results/summary.md
cat ../results/summary.md
