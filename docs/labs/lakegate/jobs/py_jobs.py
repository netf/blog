"""Long jobs for PyIceberg, DuckDB and Trino. All have the same shape as the Spark job:
read src_<engine>_<D> (D one-row data files) one file per minute, then write the rows to
tgt_<engine>_<D> and commit. Credentials are obtained once, when the job loads its tables.

python jobs/py_jobs.py --engine pyiceberg --arm c --durations 5,30,61,120 [--minute 60] [--tag x]
Prints one JSON line per job and appends it to results/<out>/jobs.jsonl."""
import argparse, json, os, sys, threading, time, traceback
from datetime import datetime, timezone
import duckdb
import pyarrow as pa, pyarrow.parquet as pq
import trino.dbapi, trino.exceptions
from pyiceberg.catalog import load_catalog

sys.path.insert(0, "/lab/kit")
import lg, lakegate_client

ARM_CATALOG = {"a": ("lake_a", "b"), "b": ("lake_b", "b"), "c": ("lake_c", "c"), "f": ("lake_f", "f")}
LK_URI = "http://lakekeeper:8181/catalog"  # arm "lk": Lakekeeper warehouse "lk", no authentication


def now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def short_error(e):
    s = f"{type(e).__name__}: {e}"
    return " ".join(s.split())[:600]


def pyiceberg_catalog(arm, principal, extra=None):
    if arm == "lk":
        return load_catalog("lk", **{"type": "rest", "uri": LK_URI, "warehouse": "lk",
                                     "header.X-Iceberg-Access-Delegation": "vended-credentials", **(extra or {})})
    cat, inst = ARM_CATALOG[arm]
    props = {"type": "rest", "uri": f"{lg.POLARIS[inst]}/api/catalog", "warehouse": cat,
             "credential": f"{principal[0]}:{principal[1]}", "scope": "PRINCIPAL_ROLE:ALL"}
    if arm == "a":
        props.update({"header.X-Iceberg-Access-Delegation": "", "s3.endpoint": lg.S3_ENDPOINT,
                      "s3.access-key-id": "pyiceberg-a", "s3.secret-access-key": "pyiceberg-a-secret-key"})
    else:
        props["header.X-Iceberg-Access-Delegation"] = "vended-credentials"
    props.update(extra or {})
    return load_catalog(cat, **props)


def job_pyiceberg(a, dur, principal, log, src_name, tgt_name):
    cat = pyiceberg_catalog(a.arm, principal)
    t0 = time.time()
    src = cat.load_table(f"{a.ns}.{src_name}")
    tgt = cat.load_table(f"{a.ns}.{tgt_name}")
    plan_s = time.time() - t0
    if a.refresh_shim:
        lakegate_client.refreshing(cat, src, log)
        lakegate_client.refreshing(cat, tgt, log)
    files = sorted(t.file.file_path for t in src.scan().plan_files())
    parts = []
    for i, f in enumerate(files):
        with src.io.new_input(f).open() as fh:
            parts.append(pq.read_table(fh))
        log(f"read file {i + 1}/{len(files)}")
        time.sleep(a.minute)
    tgt.append(pa.concat_tables(parts).cast(tgt.schema().as_arrow()))
    return {"plan_s": round(plan_s, 3), "files": len(files)}


def job_pyiceberg_tx(a, dur, principal, log, src_name, tgt_name):
    """One transaction that appends a file every minute and commits at the end (F3)."""
    cat = pyiceberg_catalog(a.arm, principal)
    tgt = cat.load_table(f"{a.ns}.{tgt_name}")
    if a.refresh_shim:
        lakegate_client.refreshing(cat, tgt, log)
    tx = tgt.transaction()
    for i in range(dur):
        tx.append(pa.table({"id": [i], "v": [f"tx-{i}"]}, schema=tgt.schema().as_arrow()))
        log(f"appended file {i + 1}/{dur} (not committed)")
        time.sleep(a.minute)
    tx.commit_transaction()
    log("committed")
    return {"appends": dur}


def duckdb_attach(a, principal):
    con = duckdb.connect()
    con.execute("SET threads=1; LOAD iceberg; LOAD httpfs")
    if a.arm == "lk":
        con.execute(f"ATTACH 'lk' AS lg (TYPE iceberg, ENDPOINT '{LK_URI}', AUTHORIZATION_TYPE 'none', "
                    "ACCESS_DELEGATION_MODE 'vended_credentials')")
        return con
    cat, inst = ARM_CATALOG[a.arm]
    con.execute(f"""CREATE SECRET pol (TYPE iceberg, CLIENT_ID '{principal[0]}', CLIENT_SECRET '{principal[1]}',
                 OAUTH2_SERVER_URI '{lg.POLARIS[inst]}/api/catalog/v1/oauth/tokens', OAUTH2_SCOPE 'PRINCIPAL_ROLE:ALL')""")
    mode = "vended_credentials"
    if a.arm == "a":
        con.execute("""CREATE SECRET s3a (TYPE s3, KEY_ID 'duckdb-a', SECRET 'duckdb-a-secret-key', REGION 'us-east-1',
                     ENDPOINT 'minio:9000', URL_STYLE 'path', USE_SSL false)""")
        mode = "none"
    con.execute(f"""ATTACH '{cat}' AS lg (TYPE iceberg, ENDPOINT '{lg.POLARIS[inst]}/api/catalog', SECRET pol,
                 ACCESS_DELEGATION_MODE '{mode}')""")
    return con


def job_duckdb_tx(a, dur, principal, log, src_name, tgt_name):
    """BEGIN; INSERT; wait <dur> minutes; INSERT; COMMIT (F3)."""
    con = duckdb_attach(a, principal)
    con.execute("BEGIN")
    con.execute(f"INSERT INTO lg.{a.ns}.{tgt_name} VALUES (1, 'tx-first')")
    log("first insert (not committed)")
    time.sleep(dur * a.minute)
    con.execute(f"INSERT INTO lg.{a.ns}.{tgt_name} VALUES (2, 'tx-second')")
    log("second insert")
    con.execute("COMMIT")
    log("committed")
    return {}


def job_duckdb(a, dur, principal, log, src_name, tgt_name):
    con = duckdb_attach(a, principal)
    state = {"n": 0}

    def slow(v):
        state["n"] += 1
        log(f"row {state['n']}")
        time.sleep(a.minute)
        return v

    con.create_function("slow", slow, ["VARCHAR"], "VARCHAR", side_effects=True)
    t0 = time.time()
    con.execute(f"INSERT INTO lg.{a.ns}.{tgt_name} SELECT id, slow(v) FROM lg.{a.ns}.{src_name}")
    return {"rows": state["n"], "statement_s": round(time.time() - t0, 1)}


TRINO_FN = """CREATE OR REPLACE FUNCTION memory.default.slow_%d(v varchar) RETURNS varchar LANGUAGE PYTHON
WITH (handler = 'f') AS $$
import time
def f(v):
    time.sleep(%d)
    return v
$$"""


def job_trino(a, dur, principal, log, src_name, tgt_name):
    conn = trino.dbapi.connect(host="trino", port=8080, user=f"lakegate-{a.arm}", catalog=a.arm, schema=a.ns,
                               session_properties={"task_concurrency": 1, "max_drivers_per_task": 1,
                                                   "task_min_writer_count": 1, "task_max_writer_count": 1},
                               request_timeout=4 * 3600)
    cur = conn.cursor()
    sec = int(a.minute)
    try:
        cur.execute(TRINO_FN % (sec, sec))
        cur.fetchall()
    except trino.exceptions.TrinoUserError as e:
        if e.error_name != "ALREADY_EXISTS":
            raise
    cur.execute(f"INSERT INTO {tgt_name} SELECT id, memory.default.slow_{sec}(v) FROM {src_name}")
    rows = cur.fetchall()
    return {"rows": rows[0][0] if rows else None, "query_id": cur.query_id}


def sweep(a, principal):
    """Observation workload: count rows of the engine's fixed table set (lg.SWEEPS)."""
    tables = [f"{ns}.t{i:03d}" for ns, i in lg.SWEEPS[a.engine]]
    if a.engine == "pyiceberg":
        cat = pyiceberg_catalog(a.arm, principal)
        return sum(cat.load_table(t).scan().to_arrow().num_rows for t in tables)
    if a.engine == "trino":
        cur = trino.dbapi.connect(host="trino", port=8080, user=f"lakegate-{a.arm}", catalog=a.arm).cursor()
        n = 0
        for t in tables:
            cur.execute(f"SELECT count(*) FROM {t}")
            n += cur.fetchall()[0][0]
        return n
    if a.engine == "duckdb":
        con = duckdb_attach(a, principal)
        return sum(con.execute(f"SELECT count(*) FROM lg.{t}").fetchall()[0][0] for t in tables)


RUNNERS = {"pyiceberg": job_pyiceberg, "duckdb": job_duckdb, "trino": job_trino}
TX_RUNNERS = {"pyiceberg": job_pyiceberg_tx, "duckdb": job_duckdb_tx}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--engine", required=True, choices=list(RUNNERS))
    p.add_argument("--arm", required=True)
    p.add_argument("--durations", default="5,30,61,120")
    p.add_argument("--minute", type=float, default=60.0, help="seconds per source file")
    p.add_argument("--refresh-shim", action="store_true")
    p.add_argument("--src", help="override source table (single duration only)")
    p.add_argument("--tgt", help="override target table (single duration only)")
    p.add_argument("--tag", default="")
    p.add_argument("--out", default="matrix")
    p.add_argument("--sweep", action="store_true")
    p.add_argument("--ns", default="ops")
    p.add_argument("--tx", action="store_true", help="long-transaction variant (pyiceberg, duckdb)")
    a = p.parse_args()
    principals = lg.load_state("principals.json")
    out_dir = os.path.join(lg.LAB, "results", a.out)
    os.makedirs(out_dir, exist_ok=True)
    lock = threading.Lock()

    def run(dur):
        src_name, tgt_name = lg.job_tables(a.engine, dur)
        src_name, tgt_name = a.src or src_name, a.tgt or tgt_name
        name = f"{a.engine}-{a.arm}-{dur}{('-' + a.tag) if a.tag else ''}"
        logf = open(os.path.join(out_dir, f"{name}.log"), "a", buffering=1)

        def log(msg):
            logf.write(f"{now()} {msg}\n")

        rec = {"job": name, "engine": a.engine, "arm": a.arm, "duration_min": dur, "tag": a.tag,
               "src": src_name, "tgt": tgt_name, "start": now()}
        t0 = time.time()
        log("start")
        try:
            runner = TX_RUNNERS[a.engine] if a.tx else RUNNERS[a.engine]
            rec.update(runner(a, dur, principals.get(a.arm, {}).get(a.engine), log, src_name, tgt_name))
            rec["ok"] = True
        except Exception as e:
            rec["ok"] = False
            rec["error"] = short_error(e)
            log("FAILED " + traceback.format_exc())
        rec["end"] = now()
        rec["elapsed_s"] = round(time.time() - t0, 1)
        log(f"end ok={rec['ok']}")
        line = json.dumps(rec)
        with lock:
            print(line, flush=True)
            with open(os.path.join(out_dir, "jobs.jsonl"), "a") as f:
                f.write(line + "\n")

    if a.sweep:
        rec = {"job": f"{a.engine}-{a.arm}-sweep", "engine": a.engine, "arm": a.arm, "start": now()}
        try:
            rec["rows"] = sweep(a, principals[a.arm][a.engine])
            rec["ok"] = True
        except Exception as e:
            rec["ok"], rec["error"] = False, short_error(e)
        rec["end"] = now()
        print(json.dumps(rec), flush=True)
        with open(os.path.join(out_dir, "jobs.jsonl"), "a") as f:
            f.write(json.dumps(rec) + "\n")
        return
    threads = [threading.Thread(target=run, args=(int(d),)) for d in a.durations.split(",")]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


if __name__ == "__main__":
    main()
