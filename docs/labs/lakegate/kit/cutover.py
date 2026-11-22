#!/usr/bin/env python3
"""Migration kit step 4: cut-over checklist. Run on the host (it calls mc through docker):
LG_POLARIS_C=http://localhost:8183 PYTHONPATH=kit python3 kit/cutover.py --catalog lake_c --instance c --out results/kit/cutover-before.txt

FAIL items block removing the bucket-wide keys; WARN items are accepted risks to write down."""
import argparse, json, subprocess, time
import requests
import lg

SERVICE_USERS = {"polaris", "lakekeeper"}  # catalog services: they must keep a key to call STS
WIDE = {"TABLE_READ_DATA", "TABLE_WRITE_DATA", "TABLE_FULL_METADATA", "CATALOG_MANAGE_CONTENT"}
MC = ["docker", "run", "--rm", "--network", "lakegate_default", "-e", "MC_HOST_l=http://admin:password123@minio:9000",
      "cgr.dev/chainguard/minio-client:latest", "--json"]


def mc(*args):
    r = subprocess.run(MC + list(args), capture_output=True, text=True, timeout=120)
    return [json.loads(l) for l in r.stdout.splitlines() if l.strip()]


def check_keys():
    users = [u for u in mc("admin", "user", "list", "l") if u.get("status") == "success"]
    wide = []
    for u in users:
        name = u.get("accessKey")
        pol = (u.get("policyName") or "").split(",")
        if name in SERVICE_USERS:
            continue
        if any(p in ("lake-rw", "readwrite", "consoleAdmin") for p in pol):
            wide.append(f"{name} ({u.get('policyName')})")
    return ("FAIL" if wide else "PASS", f"bucket-wide keys outside the catalog services: {wide or 'none'}")


def check_ttl(instance, max_ttl):
    env = subprocess.run(["docker", "inspect", f"lakegate-polaris-{instance}-1", "--format", "{{json .Config.Env}}"],
                         capture_output=True, text=True).stdout
    env = dict(e.split("=", 1) for e in json.loads(env))
    ttl = int(env.get('polaris.features."STORAGE_CREDENTIAL_DURATION_SECONDS"', 3600))
    cache = int(env.get('polaris.features."STORAGE_CREDENTIAL_CACHE_DURATION_SECONDS"', 1800))
    return ("PASS" if ttl <= max_ttl else "FAIL",
            f"credential TTL {ttl}s (target <= {max_ttl}s), cache {cache}s; a stolen key lives up to {ttl}s")


def check_catalog(pol, cat):
    c = pol.mgmt("GET", f"catalogs/{cat}")
    props = c.get("properties", {})
    overlap = props.get("polaris.config.allow.overlapping.table.location", props.get("allow.overlapping.table.location", "false"))
    sci = c.get("storageConfigInfo", {})
    res = [("FAIL" if overlap == "true" else "PASS", f"{cat}: table location overlap allowed = {overlap}")]
    res.append(("PASS" if sci.get("kmsUnavailable") or sci.get("encryptionKeys") else "WARN",
                f"{cat}: kmsUnavailable={sci.get('kmsUnavailable')} (MinIO STS rejects Polaris' default kms:* statement)"))
    return res


def check_locations(pol, cat):
    """No table location may equal or nest inside another (shared prefixes share credentials)."""
    h = pol.h()
    base = f"{pol.base}/api/catalog/v1/{cat}"
    locs = {}
    for ns in [n[0] for n in requests.get(f"{base}/namespaces", headers=h, timeout=30).json()["namespaces"]]:
        tables = requests.get(f"{base}/namespaces/{ns}/tables", headers=h, params={"pageSize": 1000}, timeout=30).json()["identifiers"]
        for t in tables:
            lt = requests.get(f"{base}/namespaces/{ns}/tables/{t['name']}", headers=h, timeout=30).json()
            locs[f"{ns}.{t['name']}"] = lt["metadata"]["location"].rstrip("/") + "/"
    items = sorted(locs.items(), key=lambda kv: kv[1])
    bad = [f"{a} {la} contains {b}" for (a, la), (b, lb) in zip(items, items[1:]) if lb.startswith(la)]
    return ("FAIL" if bad else "PASS", f"{len(locs)} table locations, shared or nested: {bad[:5] or 'none'}")


def check_grants(pol, cat):
    wide, creates = [], []
    for role in pol.mgmt("GET", f"catalogs/{cat}/catalog-roles")["roles"]:
        name = role["name"]
        if name == "catalog_admin":
            continue
        for g in pol.mgmt("GET", f"catalogs/{cat}/catalog-roles/{name}/grants")["grants"]:
            if g["type"] == "catalog" and g["privilege"] in WIDE:
                wide.append(f"{name}:{g['privilege']}")
            if g["privilege"] == "TABLE_CREATE":
                creates.append(f"{name}:{g['type']}{'/' + '.'.join(g.get('namespace', [])) if g.get('namespace') else ''}")
    out = [("FAIL" if wide else "PASS", f"catalog-wide data grants on engine roles: {wide or 'none'}")]
    if creates:
        out.append(("WARN", f"TABLE_CREATE held by {creates} (DuckDB's commit endpoint needs it)"))
    return out


def check_canary(path):
    try:
        c = json.load(open(path))
    except FileNotFoundError:
        return ("FAIL", f"no canary result at {path}")
    bad = [r["job"] for r in c["jobs"] if not r["ok"]]
    return ("PASS" if not bad else "FAIL", f"canary {c['finished']}: {len(c['jobs']) - len(bad)}/{len(c['jobs'])} engines ran past the TTL; failing: {bad or 'none'}")


def check_non_refreshing(ttl):
    margin = ttl - 300
    # Measured on lab day: PyIceberg 0.12.0 never refreshes; Trino 484 refreshes reads but not an open writer.
    long_jobs = [f"pyiceberg {d}min" for d in lg.DURATIONS if d * 60 > margin]
    return ("WARN", f"PyIceberg jobs that outlive TTL-300s={margin}s: {long_jobs} (must use lakegate_client.refreshing); "
                    f"Trino INSERTs must not hold an output file open longer than {margin}s")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--catalog", default="lake_c")
    p.add_argument("--instance", default="c")
    p.add_argument("--max-ttl", type=int, default=900)
    p.add_argument("--canary", default="results/canary/latest.json")
    p.add_argument("--out")
    a = p.parse_args()
    pol = lg.Polaris(lg.POLARIS[a.instance])
    ttl_res = check_ttl(a.instance, a.max_ttl)
    res = [check_keys(), ttl_res] + check_catalog(pol, a.catalog) + [check_locations(pol, a.catalog)] \
        + check_grants(pol, a.catalog) + [check_canary(a.canary), check_non_refreshing(int(ttl_res[1].split("TTL ")[1].split("s")[0]))]
    lines = [f"lakegate cut-over checklist  {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}  catalog={a.catalog}"]
    lines += [f"[{s}] {m}" for s, m in res]
    verdict = "BLOCKED" if any(s == "FAIL" for s, _ in res) else "READY"
    lines.append(f"verdict: {verdict} (remove bucket-wide keys only when READY)")
    txt = "\n".join(lines)
    print(txt)
    if a.out:
        open(a.out, "w").write(txt + "\n")


if __name__ == "__main__":
    main()
