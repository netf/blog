# Environment preflight

Run on 2026-10-22 before the first measurement (`scripts/00-preflight.sh`, raw output in
`results/environment-raw.txt`). Versions were pinned before any benchmark ran.

## What the lab needs and what the VM had

| need | found | status |
| --- | --- | --- |
| x86 CPU with AES-NI (Tink AES-SIV) | Intel Xeon, 4 vCPU, `aes vaes avx2 avx512f pclmulqdq sha_ni` | ok |
| RAM for 10M-row hash joins | 15 GiB total, but ~10 GiB sat in the hypervisor balloon at boot (2,621,440 pages); ~5 GiB usable at first, more later as it deflated | ok, see note 3 |
| disk for ~7 GB Postgres + ~10 GB Parquet | 246 GB free on `/dev/vdc` (same filesystem for Postgres, Parquet and DuckDB) | ok |
| virtualisation | KVM guest, PID 1 is `tini` (no systemd) | ok, see note 1 |
| kernel / cgroups | 6.12.94+, cgroup v2 | ok (not used by this lab) |
| Postgres | not installed | installed 18.6 from PGDG, see note 1 |
| Docker | not installed | not needed; Postgres runs natively, see note 2 |
| Python | 3.12.3, `python3-venv` missing | installed `python3.12-venv` |
| network | PyPI and apt.postgresql.org reachable (HTTP 200) | ok |
| clock | single process per measurement, `time.perf_counter` | no cross-process timing, NTP not needed |

## Pinned versions

PostgreSQL 18.6 (PGDG `18.6-1.pgdg24.04+2`), Python 3.12.3, tink 1.16.1, protobuf 7.36.2,
duckdb 2.0.0, pyarrow 26.0.0, adbc-driver-postgresql 1.12.0, psycopg 3.3.6, psutil 7.2.2
(`requirements.txt`).

## Deviations and workarounds

1. **No systemd.** Postgres is started with `pg_ctlcluster 18 main start` instead of a service
   unit. It runs with stock `postgresql.conf` settings (shared_buffers 128 MB); the generator sets
   `work_mem = 1GB` for its own session only.
2. **No Docker, and none used.** The brief didn't require containers, so Postgres runs natively
   on the same VM as the pipeline. Source reads go over localhost TCP and the Postgres backend
   shares the 4 vCPUs with the pipeline; its CPU is reported separately.
3. **Memory balloon.** DuckDB is capped explicitly (`memory_limit = '3GB'`, `threads = 4`) so the
   results don't depend on how far the balloon had deflated during a given run.
4. **No KMS.** The key-encryption key that wraps the per-column keysets is a local Tink AES256-GCM
   keyset file (`data/keys/kek.json`), standing in for a cloud KMS key. Column keysets on disk are
   only stored encrypted under it. This affects key custody, not any measured cost: keysets are
   unwrapped once per process.
5. **Python Tink has no KeysetManager.** Rotation (add a key, promote it, destroy the old one) edits
   the keyset protobuf directly in `scripts/keys.py`. Tink's own primitives do all the crypto.
6. **Scale.** The full requested scale ran: 10M customers and 50M orders, key rotation over all
   60M email cells. Nothing was scaled down.
