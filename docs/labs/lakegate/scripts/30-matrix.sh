#!/usr/bin/env bash
# Main measurement: arms A, B, C x 4 engines x jobs of 5, 30, 61, 120 minutes, all started together.
#   A: one bucket-wide static key per engine (lake_a, Polaris B, no vending)
#   B: vended credentials, Polaris defaults (TTL 3600 s), client defaults, catalog-wide grants
#   C: vended credentials, TTL 900 s, kit-generated per-engine grants, refresh configured,
#      PyIceberg through lakegate_client.refreshing(); DuckDB has no refresh path
set -uo pipefail
cd "$(dirname "$0")/.."
# OUT/DURATIONS overridable: the 120-minute jobs were rerun (results/incidents.md)
OUT=${OUT:-matrix}
DURATIONS=${DURATIONS:-5,30,61,120}
mkdir -p results/$OUT
date -u +%FT%TZ > results/$OUT/started.txt
( while true; do docker stats --no-stream --format "$(date -u +%FT%TZ)\t{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" >> results/$OUT/docker-stats.tsv; sleep 30; done ) &
SAMPLER=$!
for arm in a b c; do
  shim=""; sconf=""
  if [ $arm = c ]; then shim="--refresh-shim"; sconf="--conf spark.sql.catalog.lg.client.refresh-credentials-enabled=true"; fi
  for e in pyiceberg duckdb trino; do
    docker compose exec -T py python jobs/py_jobs.py --engine $e --arm $arm $shim --durations $DURATIONS --out $OUT > results/$OUT/run-$e-$arm.out 2>&1 &
  done
  docker compose exec -T spark jobs/spark-submit.sh jobs/spark_jobs.py --arm $arm $sconf --durations $DURATIONS --out $OUT > results/$OUT/run-spark-$arm.out 2>&1 &
done
wait $(jobs -p | grep -v "^$SAMPLER$")
kill $SAMPLER
for p in polaris-b polaris-c; do docker compose logs --no-color --since "$(cat results/$OUT/started.txt)" $p | grep -a ' ACCESS ' > results/$OUT/access-$p.log; done
date -u +%FT%TZ > results/$OUT/finished.txt
