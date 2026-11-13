# Lab: deterministic encryption for PII join keys

Reproduction kit for the post
[I encrypted every email address in the warehouse and the joins still work](../../../src/content/blog/encrypted-email-joins.md).
Every number in the post comes from files under `results/`, produced by the scripts here.
All data is synthetic, generated from fixed seeds.

## Reproduce

```bash
cd docs/labs/encrypted-email-joins
./reproduce.sh        # or: make reproduce. About 1.5 hours on 4 vCPUs, ~20 GB of disk
```

Smaller run: `N_CUSTOMERS=1000000 N_ORDERS=5000000 ./reproduce.sh`. Ubuntu 24.04 is assumed
(PostgreSQL comes from the PGDG apt repo); `sudo` is needed for the Postgres install.

## What it builds

- **Source:** PostgreSQL 18.6 database `shop` with `customers` (10M rows: email, phone, country,
  plan, signup date) and `orders` (50M rows keyed by the customer's email, as a separate shop
  system would send them). Names are synthetic syllable combinations; email shapes follow a
  pattern mix (`first.last`, `f.last`, digits, random handles) over free-mail and company domains;
  phones are unique `+447` numbers.
- **Pipeline** (`scripts/pipeline.py`): Postgres → Arrow over ADBC (binary COPY) → optional
  tokenization of `email`, `phone` and `orders.customer_email` → Parquet (zstd 3, 1M-row groups).
  Three variants: `plain`, `sha256` (salted SHA-256, one salt per warehouse, which is what joins
  need) and `daead` (Tink AES-SIV deterministic AEAD).
- **Keys** (`scripts/keys.py`): one Tink AES-SIV keyset per logical column (`email`, `phone`,
  `country`), envelope-encrypted under a local AES-GCM key that stands in for a KMS key. Both email
  columns use the `email` keyset and the associated data `b"email"`, otherwise they would not join.
- **Re-identification service** (`scripts/reid_service.py`): the only place tokens become
  plaintext. Bearer token → role; roles grant `reidentify` and `tokenize` per column separately,
  with a per-request cap, a per-minute budget and an audit log without values.
- **Rotation** (`scripts/rotate.py`): add a new primary key, rewrite every file holding the column,
  verify, destroy the old key.

## Run order

| step | script | output |
| --- | --- | --- |
| preflight | `scripts/00-preflight.sh` | `results/environment-raw*.txt`, `environment.md` |
| install | `scripts/01-setup.sh` | Postgres 18.6, `.venv` from `requirements.txt` |
| data | `scripts/02-generate.py` | `results/generate/` |
| ingest, 5 rounds | `scripts/03-bench-ingest.sh 5` | `results/ingest/runs.jsonl` |
| Parquet sizes | `scripts/sizes.py` | `results/sizes/sizes.json` |
| DuckDB joins, 3 rounds × 5 reps | `scripts/bench_join.py 3 5` | `results/join/runs.jsonl` |
| rotation, 3 runs | `scripts/04-rotate.sh 3` | `results/rotation/` |
| attacks, frequency, reid | `scripts/05-security.sh` | `results/attack/`, `results/frequency/`, `results/reid/` |
| sort and prefix follow-ups | `scripts/extra_layout.py` | `results/layout/` |
| tables | `scripts/summarize.py` | `results/summary.md` |

`scripts/rebuild.sh` recreates the data and warehouse on a fresh machine without overwriting the
benchmark results (used once, see `environment.md` note 7).

## Results layout

```text
results/
  environment-raw.txt, environment-raw-vm2.txt   preflight output, both VMs
  generate/      generator log
  ingest/        runs.jsonl: one line per pipeline run (rows/s, CPU, Postgres CPU, stage timings)
  sizes/         per-column stored vs logical bytes, encodings, codec check
  join/          per-query timings per round, and the identical-results check
  rotation/      email-runN.json (60M rows), phone-runN.json (10M rows)
  attack/        dictionary-runN.json, phone-runN.json
  frequency/     frequency analysis on tokenized country, randomized-AEAD control
  reid/          permission matrix, round trips, rate limit, audit log, latency
  layout/        sort.json (sorted vs unsorted orders), prefix.jsonl (Tink prefix vs stripped)
  rebuild/       VM 2 rebuild pass and the size check against VM 1
  summary.md     the tables quoted in the post
```

## Cleanup

```bash
make clean     # removes data/ and drops the shop database
```
