#!/usr/bin/env bash
# Ingest benchmark: ROUNDS rounds, the three modes in a rotated order each round, both tables.
# Appends one JSON line per run to results/ingest/runs.jsonl. The last round's files stay in
# data/warehouse/<mode>/ for the size, join, rotation and attack steps.
set -euo pipefail
cd "$(dirname "$0")"
ROUNDS=${1:-5}
PY=../.venv/bin/python
out=../results/ingest/runs.jsonl
mkdir -p ../results/ingest ../data/warehouse/{plain,sha256,daead}
: > "$out"
modes=(plain sha256 daead)
for r in $(seq 0 $((ROUNDS - 1))); do
  for i in 0 1 2; do
    m=${modes[$(( (i + r) % 3 ))]}
    for t in customers orders; do
      $PY pipeline.py "$m" "$t" "../data/warehouse/$m/$t.parquet" \
        | $PY -c "import json,sys; d=json.loads(sys.stdin.read()); d['round']=$r; print(json.dumps(d))" | tee -a "$out"
    done
  done
done
echo done > ../results/ingest/done
