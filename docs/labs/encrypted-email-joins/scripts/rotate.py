"""Rotate one column key over every Parquet file that holds that column.

    LAB_KEYS=data/rotation/keys rotate.py COLUMN RUN_ID > results/rotation/<...>.json

1. add a new primary key (old key stays ENABLED so old tokens decrypt)
2. lazy-rotation check: tokenize 100k existing customer emails under the new primary and count how
   many match tokens already in customers.parquet (what a "new keys for new rows only" rotation gives)
3. rewrite each file row group by row group: decrypt with the keyset, re-encrypt under the primary
4. verify: no token still carries the old key id, and the lazy check now matches
5. destroy the old key
"""
import json
import pathlib
import random
import resource
import sys
import time

import duckdb
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

import keys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WH = ROOT / "data" / "rotation"
FILES = {
    "email": [("customers.parquet", "email"), ("orders.parquet", "customer_email")],
    "phone": [("customers.parquet", "phone")],
}
ROW_GROUP = 1_000_000


def cpu():
    r = resource.getrusage(resource.RUSAGE_SELF)
    return r.ru_utime + r.ru_stime


def key_id(token):
    return int.from_bytes(token[1:5], "big")


def sample_plain_emails(n=100_000, seed=7):
    """Existing customers' emails as they arrive in new source rows (plaintext copy of the source)."""
    col = pq.read_table(ROOT / "data" / "warehouse" / "plain" / "customers.parquet", columns=["email"]).column("email")
    idx = random.Random(seed).sample(range(len(col)), n)
    return col.take(pa.array(idx)).to_pylist()


def lazy_match(column, plain):
    p = keys.primitive(column)
    new = {p.encrypt_deterministically(v.encode(), column.encode()) for v in plain}
    existing = pq.read_table(WH / "customers.parquet", columns=[column]).column(column)
    return pc.sum(pc.is_in(existing, value_set=pa.array(list(new), pa.binary()))).as_py() or 0


def rewrite(path, name, prim, ad, old_id):
    src = WH / path
    tmp = WH / f".{path}.rotating"
    pf = pq.ParquetFile(src)
    writer = pq.ParquetWriter(tmp, pf.schema_arrow, compression="zstd", compression_level=3)
    t_read = t_x = t_write = 0.0
    rows = leftover = 0
    dec, enc = prim.decrypt_deterministically, prim.encrypt_deterministically
    for i in range(pf.num_row_groups):
        a = time.perf_counter()
        t = pf.read_row_group(i)
        b = time.perf_counter()
        col = [enc(dec(v, ad), ad) for v in t.column(name).to_pylist()]
        leftover += sum(1 for v in col if key_id(v) == old_id)
        t = t.set_column(t.schema.get_field_index(name), name, pa.array(col, pa.binary()))
        c = time.perf_counter()
        writer.write_table(t, row_group_size=ROW_GROUP)
        d = time.perf_counter()
        t_read += b - a
        t_x += c - b
        t_write += d - c
        rows += t.num_rows
    writer.close()
    before, after = src.stat().st_size, tmp.stat().st_size
    tmp.replace(src)
    return {"file": path, "column": name, "rows": rows, "read_s": round(t_read, 2), "reencrypt_s": round(t_x, 2),
            "write_s": round(t_write, 2), "bytes_before": before, "bytes_after": after, "old_key_tokens_left": leftover}


def join_rows(d):
    con = duckdb.connect()
    con.execute("set threads = 4; set memory_limit = '3GB'")
    n = con.execute(f"""select count(*) from read_parquet('{d / "orders.parquet"}') o
                        join read_parquet('{d / "customers.parquet"}') c on o.customer_email = c.email""").fetchone()[0]
    con.close()
    return n


def main():
    column, run = sys.argv[1], sys.argv[2]
    plain = sample_plain_emails() if column == "email" else None
    old_id, new_id = keys.add_primary(column)
    out = {"column": column, "run": run, "old_key": old_id, "new_key": new_id}
    if plain:
        out["lazy_rotation_matches"] = {"sampled": len(plain), "matched": lazy_match(column, plain)}
    prim = keys.primitive(column)
    c0, t0 = cpu(), time.perf_counter()
    out["files"] = [rewrite(f, n, prim, column.encode(), old_id) for f, n in FILES[column]]
    out["wall_s"] = round(time.perf_counter() - t0, 2)
    out["cpu_s"] = round(cpu() - c0, 2)
    out["rows"] = sum(f["rows"] for f in out["files"])
    out["cpu_s_per_mrow"] = round(out["cpu_s"] / out["rows"] * 1e6, 3)
    if plain:
        out["after_rewrite_matches"] = lazy_match(column, plain)
    keys.retire(column, old_id)
    out["keyset_after"] = keys.info(column)
    out["join_rows_after"] = join_rows(WH)
    out["join_rows_plaintext"] = join_rows(ROOT / "data" / "warehouse" / "plain")
    out["peak_rss_mb"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024)
    print(json.dumps(out))


if __name__ == "__main__":
    main()
