"""Long Spark jobs, one SparkSession per arm, jobs in threads.

INSERT INTO tgt SELECT /*+ COALESCE(1) */ ... FROM src: one task walks the D one-row files of src in
order, sleeping a minute per row (java.lang.Thread.sleep through java_method), then writes and
commits tgt. The tables (and their vended credentials) are loaded once, at planning.

jobs/spark-submit.sh jobs/spark_jobs.py --arm c --durations 5,30,61,120 [--minute 60] [--conf k=v ...]"""
import argparse, json, os, sys, threading, time, traceback
from datetime import datetime, timezone
from pyspark.sql import SparkSession

sys.path.insert(0, "/lab/kit")
import lg

ARM_CATALOG = {"a": ("lake_a", "b"), "b": ("lake_b", "b"), "c": ("lake_c", "c"), "f": ("lake_f", "f")}


def now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def session(arm, principal, extra):
    c = "spark.sql.catalog.lg"
    b = (SparkSession.builder.appName(f"lakegate-{arm}").master("local[8]")
         .config("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
         .config(c, "org.apache.iceberg.spark.SparkCatalog").config(f"{c}.type", "rest"))
    if arm == "lk":
        b = (b.config(f"{c}.uri", "http://lakekeeper:8181/catalog").config(f"{c}.warehouse", "lk")
              .config(f"{c}.header.X-Iceberg-Access-Delegation", "vended-credentials"))
        for kv in extra:
            k, v = kv.split("=", 1)
            b = b.config(k, v)
        return b.getOrCreate()
    cat, inst = ARM_CATALOG[arm]
    b = (b.config(f"{c}.uri", f"{lg.POLARIS[inst]}/api/catalog")
         .config(f"{c}.warehouse", cat)
         .config(f"{c}.credential", f"{principal[0]}:{principal[1]}")
         .config(f"{c}.scope", "PRINCIPAL_ROLE:ALL"))
    if arm == "a":
        b = (b.config(f"{c}.s3.endpoint", lg.S3_ENDPOINT).config(f"{c}.s3.path-style-access", "true")
              .config(f"{c}.s3.access-key-id", "spark-a").config(f"{c}.s3.secret-access-key", "spark-a-secret-key")
              .config(f"{c}.client.region", "us-east-1"))
    else:
        b = b.config(f"{c}.header.X-Iceberg-Access-Delegation", "vended-credentials")
    for kv in extra:
        k, v = kv.split("=", 1)
        b = b.config(k, v)
    return b.getOrCreate()


def root_cause(e):
    s = str(e)
    lines = [l.strip() for l in s.splitlines() if l.strip()]
    keep = [l for l in lines if any(x in l for x in ("Exception", "Error", "Caused by", "Denied", "xpired", "403", "400"))]
    return " | ".join(keep[:6])[:900] or s[:900]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--arm", required=True)
    p.add_argument("--durations", default="5,30,61,120")
    p.add_argument("--minute", type=float, default=60.0)
    p.add_argument("--conf", action="append", default=[])
    p.add_argument("--src")
    p.add_argument("--tgt")
    p.add_argument("--tag", default="")
    p.add_argument("--out", default="matrix")
    p.add_argument("--sweep", action="store_true")
    p.add_argument("--ns", default="ops")
    a = p.parse_args()
    principal = lg.load_state("principals.json").get(a.arm, {}).get("spark")
    spark = session(a.arm, principal, a.conf)
    spark.sparkContext.setLogLevel("WARN")
    out_dir = os.path.join(lg.LAB, "results", a.out)
    os.makedirs(out_dir, exist_ok=True)
    lock = threading.Lock()
    ms = int(a.minute * 1000)

    def run(dur):
        src, tgt = lg.job_tables("spark", dur)
        src, tgt = a.src or src, a.tgt or tgt
        name = f"spark-{a.arm}-{dur}{('-' + a.tag) if a.tag else ''}"
        rec = {"job": name, "engine": "spark", "arm": a.arm, "duration_min": dur, "tag": a.tag,
               "src": src, "tgt": tgt, "start": now()}
        t0 = time.time()
        try:
            spark.sparkContext.setJobGroup(name, name)
            spark.sql(f"""INSERT INTO lg.{a.ns}.{tgt}
                SELECT /*+ COALESCE(1) */ id,
                       coalesce(java_method('java.lang.Thread', 'sleep', CAST({ms} + id * 0 AS BIGINT)), v) AS v
                FROM lg.{a.ns}.{src}""").collect()
            rec["ok"] = True
        except Exception as e:
            rec["ok"] = False
            rec["error"] = root_cause(e)
            with open(os.path.join(out_dir, f"{name}.log"), "a") as f:
                f.write(traceback.format_exc())
        rec["end"] = now()
        rec["elapsed_s"] = round(time.time() - t0, 1)
        line = json.dumps(rec)
        with lock:
            print(line, flush=True)
            with open(os.path.join(out_dir, "jobs.jsonl"), "a") as f:
                f.write(line + "\n")

    if a.sweep:
        rec = {"job": f"spark-{a.arm}-sweep", "engine": "spark", "arm": a.arm, "start": now()}
        try:
            rec["rows"] = sum(spark.sql(f"SELECT count(*) FROM lg.{ns}.t{i:03d}").collect()[0][0] for ns, i in lg.SWEEPS["spark"])
            rec["ok"] = True
        except Exception as e:
            rec["ok"], rec["error"] = False, root_cause(e)
        rec["end"] = now()
        print(json.dumps(rec), flush=True)
        with open(os.path.join(out_dir, "jobs.jsonl"), "a") as f:
            f.write(json.dumps(rec) + "\n")
        spark.stop()
        return
    threads = [threading.Thread(target=run, args=(int(d),)) for d in a.durations.split(",")]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    spark.stop()


if __name__ == "__main__":
    main()
