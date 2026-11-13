"""Brute-force every UK mobile number (+447 and 9 digits, 1e9 candidates) against the hashed and
the encrypted phone columns with DuckDB. No dictionary needed: the space is small.

DuckDB's range() source runs on one thread here (3.4M hashes/s), so the candidate numbers are
first written to a Parquet file, which DuckDB scans on all 4 threads. That step is timed too.

    attack_phone.py RUN > results/attack/phone-runN.json
"""
import json
import pathlib
import sys
import time

import duckdb

import keys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WH = ROOT / "data" / "warehouse"
CAND = ROOT / "data" / "attack" / "uk-mobile-suffixes.parquet"
SPACE = 1_000_000_000

SQL = """
select count(*) from read_parquet('{cand}') n
join read_parquet('{path}') w on unhex(sha256($salt || ('+447' || lpad(n.i::varchar, 9, '0'))::blob)) = w.phone
"""


def main():
    run = sys.argv[1] if len(sys.argv) > 1 else "0"
    CAND.parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect()
    con.execute("set threads = 4; set memory_limit = '3GB'")
    t = time.perf_counter()
    con.execute(f"copy (select i::int as i from range(0, {SPACE}) t(i)) to '{CAND}' (format parquet, row_group_size 1000000)")
    out = {"run": run, "candidates": SPACE, "duckdb": duckdb.__version__,
           "write_candidates_s": round(time.perf_counter() - t, 1)}
    for mode in ("sha256", "daead"):
        path = WH / mode / "customers.parquet"
        rows = con.execute(f"select count(*) from read_parquet('{path}')").fetchone()[0]
        t = time.perf_counter()
        hit = con.execute(SQL.format(cand=CAND, path=path), {"salt": keys.salt()}).fetchone()[0]
        s = time.perf_counter() - t
        out[mode] = {"rows": rows, "recovered": hit, "pct": round(hit / rows * 100, 2), "seconds": round(s, 1),
                     "candidates_per_s": round(SPACE / s)}
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
