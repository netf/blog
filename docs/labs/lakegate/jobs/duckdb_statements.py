"""Does a DuckDB session keep working past the TTL if the work is split into statements?
One ATTACH, then SELECT at t=0, sleep, SELECT again (a new transaction), then an INSERT.
python jobs/duckdb_statements.py <arm c|lk> <ns.table to read> <ns.table to write> <sleep_s>"""
import json, sys, time
from types import SimpleNamespace
sys.path.insert(0, "/lab/jobs")
sys.path.insert(0, "/lab/kit")
import lg
from py_jobs import duckdb_attach, now

arm, read_t, write_t, sleep_s = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
principal = lg.load_state("principals.json").get(arm, {}).get("duckdb")
con = duckdb_attach(SimpleNamespace(arm=arm), principal)
out = {"arm": arm, "read": read_t, "write": write_t, "sleep_s": sleep_s, "steps": []}


def step(label, sql):
    t = now()
    try:
        r = con.execute(sql).fetchall()
        out["steps"].append({"t": t, "step": label, "ok": True, "result": str(r)[:80]})
    except Exception as e:
        out["steps"].append({"t": t, "step": label, "ok": False, "error": " ".join(str(e).split())[:400]})


step("select at t=0", f"SELECT count(*) FROM lg.{read_t}")
time.sleep(sleep_s)
step(f"select after {sleep_s}s", f"SELECT count(*) FROM lg.{read_t}")
step(f"insert after {sleep_s}s", f"INSERT INTO lg.{write_t} VALUES (42, 'after-ttl')")
print(json.dumps(out))
with open(f"/lab/results/failure/duckdb-statements-{arm}.json", "w") as f:
    json.dump(out, f, indent=2)
