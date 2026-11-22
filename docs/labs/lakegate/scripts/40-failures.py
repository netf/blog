#!/usr/bin/env python3
"""Failure tests on Polaris F (TTL 900 s, cache 450 s), one phase at a time. Run from the lab dir.

phase1  F0 control (nothing broken), F3 credentials expire inside an open transaction (orphans),
        F4 source table renamed at minute 2, Lakekeeper canary (TTL 900 s, 20-minute jobs)
phase2  F1a catalog unreachable from minute 2 to minute 22 of a 30-minute job
phase3  F1b catalog unreachable from minute 8 to minute 14 (back before the key expires)
phase4  F2 STS unreachable from minute 2 to minute 22 (shared STS proxy: run after the matrix)
phase5  Trino on Lakekeeper (needs the lk Trino catalog, i.e. a Trino restart: after the matrix)

"Unreachable" = the container is disconnected from the Compose network, so connections fail fast
(no DNS answer), the way a crashed or partitioned catalog looks. State survives (in-memory Polaris)."""
import json, os, subprocess, sys, threading, time
from datetime import datetime, timezone

OUT = "failure"
NET = "lakegate_default"


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)


def event(msg):
    line = f"{now()} {msg}"
    print(line, flush=True)
    with open(f"results/{OUT}/events.log", "a") as f:
        f.write(line + "\n")


def py(args):
    return f"docker compose exec -T py python jobs/py_jobs.py {args} --out {OUT}"


def spark(args):
    return f"docker compose exec -T spark jobs/spark-submit.sh jobs/spark_jobs.py {args} --out {OUT}"


def mk(arm, ns, files, *names):
    r = sh(f"docker compose exec -T -e PYTHONPATH=/lab/kit py python kit/mk_tables.py {arm} {ns} {files} {' '.join(names)}")
    event(f"mk_tables {arm} {ns} {files} {names}: {r.stdout.strip()} {r.stderr.strip()[-300:]}")


def std_jobs(prefix, dur=30, minute=60):
    """Spark, Trino and PyIceberg+lakegate shim on <prefix>_<engine>_src -> _tgt."""
    common = f"--arm f --ns fail --durations {dur} --minute {minute}"
    return [spark(f"{common} --src {prefix}_spark_src --tgt {prefix}_spark_tgt --tag {prefix}"),
            py(f"--engine trino {common} --src {prefix}_trino_src --tgt {prefix}_trino_tgt --tag {prefix}"),
            py(f"--engine pyiceberg {common} --refresh-shim --src {prefix}_pyshim_src --tgt {prefix}_pyshim_tgt --tag {prefix}-shim")]


def run_all(cmds, actions=()):
    """Start all job commands, fire (delay_s, fn, label) actions, wait for the jobs."""
    procs = [subprocess.Popen(c, shell=True, stdout=open(f"results/{OUT}/run.out", "a"), stderr=subprocess.STDOUT) for c in cmds]
    t0 = time.time()
    for delay, fn, label in sorted(actions, key=lambda x: x[0]):
        time.sleep(max(0, delay - (time.time() - t0)))
        event(f"t+{time.time() - t0:.0f}s {label}: {fn()}")
    for p in procs:
        p.wait()


def disconnect(svc):
    return lambda: sh(f"docker network disconnect {NET} lakegate-{svc}-1").returncode


def reconnect(svc):
    return lambda: sh(f"docker network connect --alias {svc} {NET} lakegate-{svc}-1").returncode


def rename(src, dst):
    def f():
        code = ("import lg,requests; p=lg.Polaris(lg.POLARIS['f']); "
                f"r=requests.post(p.base+'/api/catalog/v1/lake_f/tables/rename', headers=p.h(), json={{'source':{{'namespace':['fail'],'name':'{src}'}},'destination':{{'namespace':['fail'],'name':'{dst}'}}}}); print(r.status_code)")
        return sh(f"docker compose exec -T -e PYTHONPATH=/lab/kit py python -c \"{code}\"").stdout.strip()
    return f


def phase1():
    mk("f", "fail", 30, *[f"{p}_{e}" for p in ("f0", "f4") for e in ("spark", "trino", "pyshim")], "f0_pyice", "f0_duckdb")
    mk("f", "fail", 1, "f3_pyice", "f3_pyshim", "f3_duckdb")
    mk("lk", "fail", 20, "lk_spark", "lk_pyshim", "lk_pyice", "lk_duckdb", "lk_trino")
    c30 = "--arm f --ns fail --durations 30"
    cmds = std_jobs("f0") + [
        py(f"--engine pyiceberg {c30} --src f0_pyice_src --tgt f0_pyice_tgt --tag f0-noshim"),
        py(f"--engine duckdb {c30} --src f0_duckdb_src --tgt f0_duckdb_tgt --tag f0"),
    ] + std_jobs("f4") + [
        py("--engine pyiceberg --arm f --ns fail --durations 20 --tx --src f3_pyice_src --tgt f3_pyice_tgt --tag f3-noshim"),
        py("--engine pyiceberg --arm f --ns fail --durations 20 --tx --refresh-shim --src f3_pyshim_src --tgt f3_pyshim_tgt --tag f3-shim"),
        py("--engine duckdb --arm f --ns fail --durations 17 --tx --src f3_duckdb_src --tgt f3_duckdb_tgt --tag f3"),
        spark("--arm lk --ns fail --durations 20 --src lk_spark_src --tgt lk_spark_tgt --tag lk"),
        py("--engine pyiceberg --arm lk --ns fail --durations 20 --refresh-shim --src lk_pyshim_src --tgt lk_pyshim_tgt --tag lk-shim"),
        py("--engine pyiceberg --arm lk --ns fail --durations 20 --src lk_pyice_src --tgt lk_pyice_tgt --tag lk-noshim"),
        py("--engine duckdb --arm lk --ns fail --durations 20 --src lk_duckdb_src --tgt lk_duckdb_tgt --tag lk"),
    ]
    acts = [(120, rename(f"f4_{e}_src", f"f4_{e}_src_renamed"), f"rename f4_{e}_src") for e in ("spark", "trino", "pyshim")]
    run_all(cmds, acts)


def phase2():
    mk("f", "fail", 30, *[f"f1a_{e}" for e in ("spark", "trino", "pyshim")])
    run_all(std_jobs("f1a"), [(120, disconnect("polaris-f"), "catalog DOWN"), (1320, reconnect("polaris-f"), "catalog UP")])


def phase3():
    mk("f", "fail", 30, *[f"f1b_{e}" for e in ("spark", "trino", "pyshim")])
    run_all(std_jobs("f1b"), [(480, disconnect("polaris-f"), "catalog DOWN"), (840, reconnect("polaris-f"), "catalog UP")])


def phase4():
    mk("f", "fail", 30, *[f"f2_{e}" for e in ("spark", "trino", "pyshim")])
    run_all(std_jobs("f2"), [(120, disconnect("sts"), "STS DOWN"), (1320, reconnect("sts"), "STS UP")])


def phase5():
    run_all([py("--engine trino --arm lk --ns fail --durations 20 --src lk_trino_src --tgt lk_trino_tgt --tag lk")])


if __name__ == "__main__":
    os.makedirs(f"results/{OUT}", exist_ok=True)
    for ph in sys.argv[1:]:
        event(f"=== {ph} start")
        globals()[ph]()
        event(f"=== {ph} end")
