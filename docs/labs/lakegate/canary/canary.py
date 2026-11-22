#!/usr/bin/env python3
"""lakegate long-job canary: one job per engine that runs TTL + 5 minutes against the production
catalog and client config, reading a file a minute and committing at the end. Exit 1 + ALERT
lines if any engine fails, so a scheduler (cron, Airflow, a CI job after every engine upgrade)
can page on it.

./canary/canary.py [--minutes 20] [--regressed]
--regressed adds a Spark job with client.refresh-credentials-enabled=false, standing in for an
upgrade that changes that default, to show what the alert looks like."""
import argparse, json, os, subprocess, sys, time
from datetime import datetime, timezone

OUT = "canary"
ENGINES = ["spark", "trino", "pyiceberg", "duckdb"]


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def setup(minutes, names):
    print(sh(f"docker compose exec -T -e PYTHONPATH=/lab/kit py python kit/mk_tables.py c canary {minutes} {' '.join(names)}").stdout.strip())
    code = ("import lg; p=lg.Polaris(lg.POLARIS['c'])\n"
            "for n in %r:\n"
            "    e = n.split('_')[0]; r = f'r_{e}_c'\n"
            "    p.grant('lake_c', r, {'type':'table','namespace':['canary'],'tableName':f'{n}_src','privilege':'TABLE_READ_DATA'})\n"
            "    p.grant('lake_c', r, {'type':'table','namespace':['canary'],'tableName':f'{n}_tgt','privilege':'TABLE_WRITE_DATA'})\n"
            "    if e == 'duckdb':\n"
            "        p.grant('lake_c', r, {'type':'table','namespace':['canary'],'tableName':f'{n}_tgt','privilege':'TABLE_WRITE_PROPERTIES'})\n"
            "        p.grant('lake_c', r, {'type':'namespace','namespace':['canary'],'privilege':'TABLE_CREATE'})\n"
            "print('grants ok')\n") % (names,)
    r = subprocess.run(["docker", "compose", "exec", "-T", "-e", "PYTHONPATH=/lab/kit", "py", "python", "-c", code], capture_output=True, text=True)
    print(r.stdout.strip(), r.stderr.strip()[-300:])


def cmd(engine, name, minutes, tag, extra=""):
    common = f"--arm c --ns canary --durations {minutes} --src {name}_src --tgt {name}_tgt --tag {tag} --out {OUT}"
    if engine == "spark":
        return f"docker compose exec -T spark jobs/spark-submit.sh jobs/spark_jobs.py {common} {extra}"
    shim = "--refresh-shim" if engine == "pyiceberg" else ""
    return f"docker compose exec -T py python jobs/py_jobs.py --engine {engine} {common} {shim}"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--minutes", type=int, default=20)
    p.add_argument("--regressed", action="store_true")
    a = p.parse_args()
    run = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    os.makedirs(f"results/{OUT}", exist_ok=True)
    names = list(ENGINES) + (["spark_regressed"] if a.regressed else [])
    setup(a.minutes, names)
    jobs = {n: cmd(n.split("_")[0], n, a.minutes, f"{run}-{n}") for n in ENGINES}
    if a.regressed:
        jobs["spark_regressed"] = cmd("spark", "spark_regressed", a.minutes, f"{run}-spark_regressed",
                                      "--conf spark.sql.catalog.lg.client.refresh-credentials-enabled=false")
    procs = {n: subprocess.Popen(c, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for n, c in jobs.items()}
    for pr in procs.values():
        pr.wait()
    recs = [json.loads(l) for l in open(f"results/{OUT}/jobs.jsonl") if run in l]
    normal = [r for r in recs if "regressed" not in r["tag"]]
    summary = {"run": run, "finished": datetime.now(timezone.utc).isoformat(timespec="seconds"),
               "minutes": a.minutes, "jobs": [{"job": r["job"], "ok": r["ok"], "elapsed_s": r["elapsed_s"],
                                               "error": r.get("error", "")[:300]} for r in normal]}
    json.dump(summary, open(f"results/{OUT}/latest.json", "w"), indent=2)
    json.dump({**summary, "jobs": [{"job": r["job"], "ok": r["ok"], "elapsed_s": r["elapsed_s"], "error": r.get("error", "")[:300]} for r in recs]},
              open(f"results/{OUT}/{run}.json", "w"), indent=2)
    failed = [r for r in recs if not r["ok"]]
    for r in recs:
        print(("ALERT " if not r["ok"] else "ok    ") + f"{r['job']} {r['elapsed_s']}s {r.get('error', '')[:200]}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
