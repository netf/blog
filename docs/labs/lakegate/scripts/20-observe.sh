#!/usr/bin/env bash
# Observation window for the migration kit: arm A (one bucket-wide key per engine) runs each
# engine's sweep and its four jobs with 1 s per source file. Only the audit log is used afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -c "import json,datetime;json.dump({'start':datetime.datetime.now(datetime.timezone.utc).isoformat()},open('state/observe-window.json','w'))"
for e in pyiceberg duckdb trino; do
  docker compose exec -T py python jobs/py_jobs.py --engine $e --arm a --sweep --out observe &
  docker compose exec -T py python jobs/py_jobs.py --engine $e --arm a --minute 1 --out observe &
done
docker compose exec -T spark jobs/spark-submit.sh jobs/spark_jobs.py --arm a --sweep --out observe 2>/dev/null | grep '^{' &
docker compose exec -T spark jobs/spark-submit.sh jobs/spark_jobs.py --arm a --minute 1 --out observe 2>/dev/null | grep '^{' &
wait
sleep 5
python3 -c "
import json,datetime;w=json.load(open('state/observe-window.json'));w['end']=datetime.datetime.now(datetime.timezone.utc).isoformat();json.dump(w,open('state/observe-window.json','w'))"
