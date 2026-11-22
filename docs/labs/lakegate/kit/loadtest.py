"""Catalog load at 50 concurrent jobs (Polaris C, TTL 900 s). Runs in the py container.

python kit/loadtest.py <vended|plain> <burst|loop> [seconds]
A "job" here is its catalog traffic only: loadTable(src) + loadTable(tgt) [+ GET .../credentials
for src when vended], as a job does at planning time and at each refresh. Each of the 50 workers
uses its own OAuth token for one of the four arm-C engine principals and only tables that principal
is granted. burst: every worker does one job at the same moment. loop: back-to-back jobs.
Writes results/load/<mode>-<shape>.json."""
import json, statistics, sys, threading, time
import requests
import lg

N = 50
mode, shape = sys.argv[1], sys.argv[2]
seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 120
inv = json.load(open("/lab/results/kit/grants-plan.json"))
principals = lg.load_state("principals.json")["c"]
base = f"{lg.POLARIS['c']}/api/catalog/v1/lake_c"
lat = {"loadTable": [], "credentials": []}
errors = []
lock = threading.Lock()
barrier = threading.Barrier(N)


def worker(i):
    engine = lg.ENGINES[i % 4]
    cid, secret = principals[engine]
    tok = lg.Polaris(lg.POLARIS["c"], cid, secret).token()
    s = requests.Session()
    h = {"Authorization": f"Bearer {tok}"}
    if mode == "vended":
        h["X-Iceberg-Access-Delegation"] = "vended-credentials"
    tables = [g for g in inv[engine]["grants"] if g["type"] == "table"]
    k = i

    def call(kind, url):
        t0 = time.perf_counter()
        r = s.get(url, headers=h, timeout=60)
        dt = (time.perf_counter() - t0) * 1000
        with lock:
            (lat[kind] if r.status_code == 200 else errors).append(dt if r.status_code == 200 else r.status_code)

    def job():
        nonlocal k
        a, b = tables[k % len(tables)], tables[(k + 1) % len(tables)]
        k += 2
        for g in (a, b):
            call("loadTable", f"{base}/namespaces/{g['namespace'][0]}/tables/{g['tableName']}")
        if mode == "vended":
            call("credentials", f"{base}/namespaces/{a['namespace'][0]}/tables/{a['tableName']}/credentials")

    barrier.wait()
    if shape == "burst":
        job()
        return
    end = time.time() + seconds
    while time.time() < end:
        job()


t0 = time.time()
th = [threading.Thread(target=worker, args=(i,)) for i in range(N)]
for t in th:
    t.start()
for t in th:
    t.join()
wall = time.time() - t0


def pct(xs, p):
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))], 1) if xs else None


out = {"mode": mode, "shape": shape, "workers": N, "wall_s": round(wall, 1), "errors": len(errors),
       "error_codes": sorted(set(errors))}
for kind, xs in lat.items():
    if xs:
        out[kind] = {"n": len(xs), "per_s": round(len(xs) / wall, 1), "p50_ms": pct(xs, 50), "p95_ms": pct(xs, 95),
                     "p99_ms": pct(xs, 99), "max_ms": round(max(xs), 1), "mean_ms": round(statistics.mean(xs), 1)}
json.dump(out, open(f"/lab/results/load/{mode}-{shape}.json", "w"), indent=2)
print(json.dumps(out))
