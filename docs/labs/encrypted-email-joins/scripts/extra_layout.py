"""Two follow-ups after the main runs.

sort    Rewrite orders with DuckDB, unsorted and sorted by customer_email, for each variant. Sorting
        puts equal tokens next to each other, which zstd can exploit even though each token is random.
prefix  Every Tink token starts with the same 5 bytes (version byte + key id). DuckDB compares
        strings by a 4-byte prefix first, so that prefix may be useless for tokens. Time the join on
        tokens with and without those 5 bytes, after checking that a RAW-prefix Tink key produces
        exactly the stripped bytes.

    extra_layout.py sort   > results/layout/sort.json
    extra_layout.py prefix ROUNDS REPS > results/layout/prefix.jsonl
"""
import json
import pathlib
import statistics
import sys
import time

import duckdb
import pyarrow.parquet as pq
import tink
from tink import daead, secret_key_access
from tink.proto import tink_pb2

import keys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WH = ROOT / "data" / "warehouse"
OUT = ROOT / "data" / "layout"
MODES = ["plain", "sha256", "daead"]


def con():
    c = duckdb.connect()
    c.execute(f"set threads = 4; set memory_limit = '3GB'; set temp_directory = '{OUT / 'tmp'}'")
    return c


def col_bytes(path, name):
    md = pq.ParquetFile(path).metadata
    return sum(md.row_group(i).column(j).total_compressed_size for i in range(md.num_row_groups)
               for j in range(md.num_columns) if md.row_group(i).column(j).path_in_schema == name)


def sort():
    OUT.mkdir(parents=True, exist_ok=True)
    res = {}
    for mode in MODES:
        for kind, order in (("unsorted", ""), ("sorted", "order by customer_email")):
            dst = OUT / f"orders-{mode}-{kind}.parquet"
            c = con()
            t = time.perf_counter()
            c.execute(f"""copy (select * from read_parquet('{WH / mode / 'orders.parquet'}') {order})
                          to '{dst}' (format parquet, compression zstd, compression_level 3, row_group_size 1000000)""")
            s = time.perf_counter() - t
            c.close()
            res[f"{mode}/{kind}"] = {"file_bytes": dst.stat().st_size, "customer_email_bytes": col_bytes(dst, "customer_email"),
                                     "seconds": round(s, 1)}
    print(json.dumps(res, indent=1))


def raw_matches_stripped():
    ks = tink_pb2.Keyset.FromString(tink.proto_keyset_format.serialize(keys.load("email"), secret_key_access.TOKEN))
    for k in ks.key:
        k.output_prefix_type = tink_pb2.RAW
    raw = tink.proto_keyset_format.parse(ks.SerializeToString(), secret_key_access.TOKEN).primitive(daead.DeterministicAead)
    tinkp = keys.primitive("email")
    sample = [f"user{i}@example.com".encode() for i in range(1000)]
    return all(raw.encrypt_deterministically(v, b"email") == tinkp.encrypt_deterministically(v, b"email")[5:] for v in sample)


QUERIES = {
    "join_agg": """select c.country, count(*), sum(o.amount_pence) from {o} o join {c} c on o.customer_email = c.email
                   group by 1 order by 1""",
    "distinct": "select count(distinct customer_email) from {o}",
    "point": "select count(*), sum(amount_pence) from {o} where customer_email = (select email from {c} where customer_id = 1)",
}


def prefix(rounds, reps):
    print(json.dumps({"raw_prefix_tink_equals_stripped_token": raw_matches_stripped()}), flush=True)
    OUT.mkdir(parents=True, exist_ok=True)
    db = OUT / "prefix.duckdb"
    db.unlink(missing_ok=True)
    c = duckdb.connect(str(db))
    c.execute(f"set threads = 4; set memory_limit = '3GB'; set temp_directory = '{OUT / 'tmp'}'")
    src = WH / "daead"
    # Both variants go through the same expression so they are built and stored the same way.
    for name, start in (("tinkprefix", 1), ("stripped", 6)):
        c.execute(f"""create table c_{name} as select customer_id, unhex(substr(hex(email), {2 * start - 1})) as email, country
                      from read_parquet('{src / 'customers.parquet'}')""")
        c.execute(f"""create table o_{name} as select unhex(substr(hex(customer_email), {2 * start - 1})) as customer_email, amount_pence
                      from read_parquet('{src / 'orders.parquet'}')""")
    c.execute(f"create table c_plaintext as select customer_id, email, country from read_parquet('{WH / 'plain' / 'customers.parquet'}')")
    c.execute(f"create table o_plaintext as select customer_email, amount_pence from read_parquet('{WH / 'plain' / 'orders.parquet'}')")
    variants = ["plaintext", "tinkprefix", "stripped"]
    answers = {}
    for r in range(rounds):
        for name in variants[r % 3:] + variants[:r % 3]:
            for q, sql in QUERIES.items():
                text = sql.format(o=f"o_{name}", c=f"c_{name}")
                answers.setdefault(q, {})[name] = c.execute(text).fetchall()
                ms = []
                for _ in range(reps):
                    t = time.perf_counter()
                    c.execute(text).fetchall()
                    ms.append(round((time.perf_counter() - t) * 1000, 2))
                print(json.dumps({"round": r, "variant": name, "query": q, "ms": ms, "median": statistics.median(ms)}), flush=True)
    print(json.dumps({"identical_results": all(len({json.dumps(v, default=str) for v in d.values()}) == 1 for d in answers.values())}), flush=True)
    c.close()


if __name__ == "__main__":
    if sys.argv[1] == "sort":
        sort()
    else:
        prefix(int(sys.argv[2]), int(sys.argv[3]))
