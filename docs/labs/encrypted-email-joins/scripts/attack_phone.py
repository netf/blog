"""Brute-force every UK mobile number (+447 and 9 digits, 1e9 candidates) against the hashed and
the encrypted phone columns, in one DuckDB query. No dictionary needed: the space is small.

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
SPACE = 1_000_000_000

SQL = """
with cand as (select '+447' || lpad(i::varchar, 9, '0') as phone from range(0, {space}) t(i))
select count(*) from cand
join read_parquet('{path}') w on unhex(sha256($salt || cand.phone::blob)) = w.phone
"""


def main():
    run = sys.argv[1] if len(sys.argv) > 1 else "0"
    con = duckdb.connect()
    con.execute("set threads = 4; set memory_limit = '3GB'")
    out = {"run": run, "candidates": SPACE, "duckdb": duckdb.__version__}
    for mode in ("sha256", "daead"):
        path = WH / mode / "customers.parquet"
        rows = con.execute(f"select count(*) from read_parquet('{path}')").fetchone()[0]
        t = time.perf_counter()
        hit = con.execute(SQL.format(space=SPACE, path=path), {"salt": keys.salt()}).fetchone()[0]
        s = time.perf_counter() - t
        out[mode] = {"rows": rows, "recovered": hit, "pct": round(hit / rows * 100, 2), "seconds": round(s, 1),
                     "candidates_per_s": round(SPACE / s)}
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
