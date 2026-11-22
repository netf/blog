#!/usr/bin/env bash
# Whole lab, in the order it was run on 2026-11-22. Ubuntu 24.04, 4 vCPU, 15 GiB, sudo, Docker.
# About 4.5 hours, most of it the 120-minute jobs. Results land in results/, summary in results/summary.md.
set -euo pipefail
cd "$(dirname "$0")/.."
X="docker compose exec -T -e PYTHONPATH=/lab/kit:/lab/escape py python"

./scripts/01-preflight.sh > results/preflight/preflight.txt 2>&1 || true
./scripts/10-up.sh                                   # MinIO (Chainguard), 3x Polaris, Lakekeeper, Trino, Spark, 3 lakes of 300 tables
$X kit/setup_lake.py lake_f                          # failure-test lake
docker compose up -d sts-f                           # lake_f gets its own STS proxy
$X -c "import lg,requests;p=lg.Polaris(lg.POLARIS['f']);c=p.mgmt('GET','catalogs/lake_f');s=c['storageConfigInfo'];s['stsEndpoint']='http://sts-f:9000';print(requests.put(p.base+'/api/management/v1/catalogs/lake_f',headers=p.h(),json={'currentEntityVersion':c['entityVersion'],'storageConfigInfo':s,'properties':c['properties']}).status_code)"
docker compose --profile engines restart trino && sleep 30   # picks up the generated catalog files

# Migration kit: observe arm A, inventory from the audit log, generate and apply arm C grants
./scripts/20-observe.sh
python3 kit/inventory.py results/audit/audit.jsonl state/observe-window.json results/observe/jobs.jsonl
$X kit/grants.py --apply
$X kit/lakekeeper_probe.py

# Main matrix (A, B, C x 4 engines x 5/30/61/120 min) and, alongside it, the security tests
tmux new-session -d -s matrix ./scripts/30-matrix.sh
sleep 120
for arm in a b c; do $X escape/blast_radius.py $arm; done
$X escape/location_tests.py
$X escape/location_tests.py overlap
docker compose exec -T spark jobs/spark-submit.sh escape/spark_fileio_props.py --arm c | grep FILEIO_PROPS > results/escape/spark-fileio-props.txt
./scripts/40-failures.py phase1 phase2 phase3_rerun phase4 phase5
while tmux has-session -t matrix 2>/dev/null && [ ! -f results/matrix/finished.txt ]; do sleep 60; done

./scripts/50-load.sh
./canary/canary.py --regressed || true                # exits 1 when any engine fails past the TTL
LAB=$PWD LG_POLARIS_C=http://localhost:8183 PYTHONPATH=kit python3 kit/cutover.py --out results/kit/cutover-before.txt || true
python3 scripts/60-analyze.py
