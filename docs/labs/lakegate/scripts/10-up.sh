#!/usr/bin/env bash
# Brings the lab up from nothing: object store + users, catalogs, the 300-table lakes, engines.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/00-host.sh
docker build -q -t lakegate-py:1 images/py >/dev/null
docker build -q -t lakegate-spark:1 images/spark >/dev/null
mkdir -p results/audit state
docker compose up -d --wait minio audit sts
MC="docker run --rm --network lakegate_default -e MC_HOST_l=http://admin:password123@minio:9000 cgr.dev/chainguard/minio-client:latest"
$MC mb -p l/lake
cat > state/lake-rw.json <<'J'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::lake","arn:aws:s3:::lake/*"]}]}
J
docker run --rm --network lakegate_default -v "$PWD/state:/s:ro" -e MC_HOST_l=http://admin:password123@minio:9000 \
  cgr.dev/chainguard/minio-client:latest admin policy create l lake-rw /s/lake-rw.json
# Catalog service users (they call STS AssumeRole) and arm A's one bucket-wide key per engine.
for u in polaris:polaris-secret-key lakekeeper:lakekeeper-secret-key spark-a:spark-a-secret-key \
         trino-a:trino-a-secret-key pyiceberg-a:pyiceberg-a-secret-key duckdb-a:duckdb-a-secret-key; do
  $MC admin user add l "${u%%:*}" "${u#*:}"
  $MC admin policy attach l lake-rw --user "${u%%:*}" || true
done
docker compose up -d --wait polaris-b polaris-c polaris-f lakekeeper py
sleep 5
docker compose exec -T -e PYTHONPATH=/lab/kit py python kit/setup_lake.py lake_a lake_b lake_c
docker compose exec -T -e PYTHONPATH=/lab/kit py python kit/principals.py
docker compose --profile engines up -d --wait trino spark
