# lakegate lab

Per-table storage credentials vended by an Iceberg REST catalog (Polaris, Lakekeeper) through
MinIO STS, and what happens to jobs that outlive the TTL.

**State: stopped at preflight.** Two pinned components are not available as specified (upstream
MinIO images; Spark 4.3.0 with Iceberg 1.12.0). See `environment.md` for the evidence and the
options. No measurements have been taken and the post has not been written.

```
scripts/00-host.sh               dockerd without systemd + legacy FORWARD fix
scripts/01-preflight.sh          raw environment facts  -> results/preflight/preflight.txt
scripts/02-memory-bringup.sh     whole stack up once    -> results/preflight/memory-bringup.txt
scripts/03-polaris-minio-probe.py  Polaris + MinIO STS feasibility -> results/preflight/polaris-minio-probe.json
preflight/compose.memory.yaml    stack used for the memory bring-up
preflight/compose.probe.yaml     MinIO + Polaris for the probe
```

Reproduce the preflight:

```bash
cd docs/labs/lakegate
./scripts/00-host.sh
python3 -m venv /tmp/lgvenv && /tmp/lgvenv/bin/pip install "pyiceberg[pyarrow]==0.12.0" duckdb==2.0.1 boto3 requests
./scripts/01-preflight.sh > results/preflight/preflight.txt 2>&1
./scripts/02-memory-bringup.sh
docker compose -f preflight/compose.probe.yaml up -d --wait
docker run --rm --network host -e MC_HOST_l=http://admin:password123@localhost:9000 \
  cgr.dev/chainguard/minio-client:latest admin user add l polaris polaris-secret
docker run --rm --network host -e MC_HOST_l=http://admin:password123@localhost:9000 \
  cgr.dev/chainguard/minio-client:latest admin policy attach l readwrite --user polaris
grep -q ' minio$' /etc/hosts || echo '127.0.0.1 minio' | sudo tee -a /etc/hosts
/tmp/lgvenv/bin/python scripts/03-polaris-minio-probe.py
```
