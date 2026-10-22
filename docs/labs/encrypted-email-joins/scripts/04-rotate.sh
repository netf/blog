#!/usr/bin/env bash
# Key rotation benchmark. Each run starts from a fresh copy of the AES-SIV warehouse and its keys,
# rotates the email key (customers + orders, 60M rows) and then the phone key (customers, 10M rows).
set -euo pipefail
cd "$(dirname "$0")"
RUNS=${1:-3}
PY=../.venv/bin/python
mkdir -p ../results/rotation
for r in $(seq 1 "$RUNS"); do
  rm -rf ../data/rotation
  mkdir -p ../data/rotation
  cp ../data/warehouse/daead/customers.parquet ../data/warehouse/daead/orders.parquet ../data/rotation/
  cp -r ../data/keys ../data/rotation/keys
  sync
  LAB_KEYS=../data/rotation/keys $PY rotate.py email "$r" | tee "../results/rotation/email-run$r.json"
  LAB_KEYS=../data/rotation/keys $PY rotate.py phone "$r" | tee "../results/rotation/phone-run$r.json"
done
