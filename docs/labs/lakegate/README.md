# lakegate lab

Per-table storage credentials vended by an Iceberg REST catalog (Polaris 1.9.0, Lakekeeper v0.15.1)
through MinIO STS, the migration kit that gets a lake there, and what happens to jobs that outlive
the TTL. Post: `src/content/blog/vended-credentials-300-tables-to-1.md`.

Read first: `environment.md` (preflight, Piotr's decisions, pins, workarounds),
`results/incidents.md` (VM pauses; why there are no 120-minute results), `results/summary.md`
(generated tables).

```
compose.yaml                 MinIO (Chainguard fork build), audit collector, STS proxies, Polaris B/C/F,
                             Lakekeeper + Postgres, Trino, Spark, Python clients
images/                      lakegate-py (PyIceberg, DuckDB, trino client), lakegate-spark (+boto3)
config/trino/                Trino config (one driver per task) and catalogs (generated ones are gitignored)
kit/                         migration kit and lab helpers
  inventory.py               1. keys -> tables, from the MinIO audit log only
  grants.py                  2. catalog roles and grants from the inventory
  clients/                   3. per-engine client config; lakegate_client.py is the PyIceberg refresh shim
  cutover.py                 4. cut-over checklist (FAIL blocks removing bucket keys)
  lg.py, setup_lake.py, principals.py, mk_tables.py, orphans.py, loadtest.py, lakekeeper_probe.py
escape/                      escape tester, blast radius, shared-location tests, Spark FileIO dump
canary/canary.py             long-job canary (TTL + 5 min per engine, exit 1 on failure)
jobs/                        job runners: spark_jobs.py, py_jobs.py (PyIceberg, DuckDB, Trino), duckdb_statements.py
scripts/                     00 host, 01 preflight, 02 memory, 03 probe, 10 up, 20 observe, 30 matrix,
                             40 failures, 50 load, 60 analyze, reproduce.sh
results/                     raw results (matrix, matrix-120, escape, failure, load, kit, canary, lakekeeper,
                             preflight); the 403 MB MinIO audit log is not committed
```

Reproduce: `bash scripts/reproduce.sh` (Ubuntu 24.04, 4 vCPU, 15 GiB, Docker, sudo; about 4.5 hours).
