#!/usr/bin/env bash
# Rebuild the dataset and warehouse on a fresh VM without touching the benchmark results:
# same seeds, new keys, one ingest pass per variant logged to results/rebuild/ingest-vm2.jsonl.
set -euo pipefail
cd "$(dirname "$0")"
PY=../.venv/bin/python
mkdir -p ../results/rebuild ../data/warehouse/{plain,sha256,daead}
/usr/lib/postgresql/18/bin/postgres --version > ../results/rebuild/versions.txt
$PY 02-generate.py | tee ../results/rebuild/generate.log
$PY keys.py
: > ../results/rebuild/ingest-vm2.jsonl
for m in plain sha256 daead; do
  for t in customers orders; do
    $PY pipeline.py "$m" "$t" "../data/warehouse/$m/$t.parquet" | tee -a ../results/rebuild/ingest-vm2.jsonl
  done
done
