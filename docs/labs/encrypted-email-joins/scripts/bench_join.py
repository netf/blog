"""DuckDB join latency on plaintext vs hashed vs AES-SIV email keys.

    bench_join.py ROUNDS REPS > results/join/runs.jsonl

Each round visits the three variants in a rotated order; each query runs once to warm up, then
REPS timed times. Queries run on native DuckDB tables and straight off the Parquet files.
"""
import json
import pathlib
import sys
import time

import duckdb

ROOT = pathlib.Path(__file__).resolve().parent.parent
WH = ROOT / "data" / "warehouse"
MODES = ["plain", "sha256", "daead"]
SETTINGS = "set threads = 4; set memory_limit = '3GB'; set preserve_insertion_order = false;"

QUERIES = {
    "join_agg": """select c.country, count(*) n, sum(o.amount_pence) pence
                   from {o} o join {c} c on o.customer_email = c.email
                   group by c.country order by c.country""",
    "distinct": "select count(distinct customer_email) from {o}",
    "point": "select count(*), sum(amount_pence) from {o} where customer_email = $key",
}


def db(mode):
    path = WH / f"{mode}.duckdb"
    con = duckdb.connect(str(path))
    con.execute(SETTINGS)
    have = {r[0] for r in con.execute("select table_name from information_schema.tables").fetchall()}
    for t in ("customers", "orders"):
        if t not in have:
            con.execute(f"create table {t} as select * from read_parquet('{WH / mode / (t + '.parquet')}')")
    return con


def sources(mode, kind):
    if kind == "table":
        return {"c": "customers", "o": "orders"}
    return {"c": f"read_parquet('{WH / mode / 'customers.parquet'}')", "o": f"read_parquet('{WH / mode / 'orders.parquet'}')"}


def main():
    rounds, reps = int(sys.argv[1]), int(sys.argv[2])
    cons = {m: db(m) for m in MODES}
    # The point lookup uses the same customer in every variant: the one with the most orders.
    heavy_id = cons["plain"].execute("""select c.customer_id from orders o join customers c on o.customer_email = c.email
                                        group by 1 order by count(*) desc, 1 limit 1""").fetchone()[0]
    keys = {m: cons[m].execute("select email from customers where customer_id = ?", [heavy_id]).fetchone()[0] for m in MODES}
    answers = {}
    for r in range(rounds):
        order = MODES[r % 3:] + MODES[:r % 3]
        for mode in order:
            con = cons[mode]
            for kind in ("table", "parquet"):
                for q, sql in QUERIES.items():
                    text = sql.format(**sources(mode, kind))
                    params = {"key": keys[mode]} if q == "point" else None
                    res = con.execute(text, params).fetchall()
                    answers.setdefault((kind, q), {})[mode] = res
                    times = []
                    for _ in range(reps):
                        t = time.perf_counter()
                        con.execute(text, params).fetchall()
                        times.append(time.perf_counter() - t)
                    print(json.dumps({"round": r, "mode": mode, "source": kind, "query": q,
                                      "ms": [round(x * 1000, 2) for x in times]}), flush=True)
    same = all(len({json.dumps(v, default=str) for v in d.values()}) == 1 for d in answers.values())
    print(json.dumps({"check": "identical_results_across_modes", "ok": same, "heavy_customer_id": heavy_id,
                      "sample": {f"{k[0]}/{k[1]}": d["plain"][:3] for k, d in answers.items()}}, default=str), flush=True)


if __name__ == "__main__":
    main()
