"""Postgres -> Parquet ingestion with optional PII tokenization.

    pipeline.py MODE TABLE OUT.parquet
      MODE   plain | sha256 | daead
      TABLE  customers | orders

PII columns: customers.email, customers.phone, orders.customer_email. Both email columns use the
same `email` keyset and associated data, otherwise the tokens would not join. Prints one JSON line.
"""
import hashlib
import json
import os
import resource
import sys
import time

import adbc_driver_postgresql.dbapi as pg
import psutil
import pyarrow as pa
import pyarrow.parquet as pq

import keys

URI = os.environ.get("LAB_PG_URI", "postgresql://lab:lab@localhost/shop")
ROW_GROUP = 1_000_000

PII = {
    "customers": {"email": "email", "phone": "phone"},
    "orders": {"customer_email": "email"},
}
SELECT = {
    "customers": "select customer_id, email, phone, country, plan, signup_date from customers",
    "orders": "select order_id, customer_email, amount_pence, ordered_at, status from orders",
}


def tokenizer(mode, logical):
    if mode == "daead":
        p = keys.primitive(logical)
        ad = logical.encode()
        enc = p.encrypt_deterministically
        return lambda vals: pa.array([enc(v.encode(), ad) for v in vals], pa.binary())
    if mode == "sha256":
        salt = keys.salt()
        sha = hashlib.sha256
        return lambda vals: pa.array([sha(salt + v.encode()).digest() for v in vals], pa.binary(32))
    raise ValueError(mode)


def transform(table, fns):
    for name, fn in fns.items():
        i = table.schema.get_field_index(name)
        table = table.set_column(i, name, fn(table.column(name).to_pylist()))
    return table


def main():
    mode, tname, out = sys.argv[1], sys.argv[2], sys.argv[3]
    fns = {} if mode == "plain" else {c: tokenizer(mode, lg) for c, lg in PII[tname].items()}
    me = psutil.Process()
    conn = pg.connect(URI)
    cur = conn.cursor()
    cur.execute("select pg_backend_pid()")
    backend = psutil.Process(cur.fetchone()[0])
    pg0 = backend.cpu_times()
    r0 = resource.getrusage(resource.RUSAGE_SELF)
    t0 = time.perf_counter()
    t_read = t_xform = t_write = 0.0
    rows = 0
    writer = None
    pending, pending_rows = [], 0

    def flush():
        nonlocal writer, t_xform, t_write, rows, pending, pending_rows
        if not pending:
            return
        tbl = pa.Table.from_batches(pending)
        pending, pending_rows = [], 0
        a = time.perf_counter()
        tbl = transform(tbl, fns)
        b = time.perf_counter()
        if writer is None:
            writer = pq.ParquetWriter(out, tbl.schema, compression="zstd", compression_level=3)
        writer.write_table(tbl, row_group_size=ROW_GROUP)
        c = time.perf_counter()
        t_xform += b - a
        t_write += c - b
        rows += tbl.num_rows

    a = time.perf_counter()
    cur.execute(SELECT[tname])
    reader = cur.fetch_record_batch()
    t_read += time.perf_counter() - a
    while True:
        a = time.perf_counter()
        try:
            batch = reader.read_next_batch()
        except StopIteration:
            t_read += time.perf_counter() - a
            break
        t_read += time.perf_counter() - a
        pending.append(batch)
        pending_rows += batch.num_rows
        if pending_rows >= ROW_GROUP:
            flush()
    flush()
    writer.close()
    wall = time.perf_counter() - t0
    r1 = resource.getrusage(resource.RUSAGE_SELF)
    pg1 = backend.cpu_times()
    cur.close()
    conn.close()
    cpu = (r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)
    pg_cpu = (pg1.user - pg0.user) + (pg1.system - pg0.system)
    print(json.dumps({
        "mode": mode, "table": tname, "rows": rows, "wall_s": round(wall, 3),
        "rows_per_s": round(rows / wall), "cpu_s": round(cpu, 3),
        "cpu_s_per_mrow": round(cpu / rows * 1e6, 3), "pg_cpu_s": round(pg_cpu, 3),
        "read_s": round(t_read, 3), "transform_s": round(t_xform, 3), "write_s": round(t_write, 3),
        "peak_rss_mb": round(r1.ru_maxrss / 1024), "out_bytes": os.path.getsize(out),
        "rss_now_mb": round(me.memory_info().rss / 2**20),
    }))


if __name__ == "__main__":
    main()
