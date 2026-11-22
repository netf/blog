"""Lakekeeper v0.15.1 + MinIO STS probe. Runs in the py container; writes the vended configs to
state/lk-*.json for the escape tester (run on the host) and results/lakekeeper/probe.json."""
import json, time
import pyarrow as pa, requests
from pyiceberg.catalog import load_catalog
import lg

LK = "http://lakekeeper:8181"
out = {}

r = requests.post(f"{LK}/management/v1/bootstrap", json={"accept-terms-of-use": True}, timeout=30)
out["bootstrap"] = r.status_code
wh = {"warehouse-name": "lk",
      "storage-profile": {"type": "s3", "bucket": lg.BUCKET, "key-prefix": "lk", "region": "us-east-1",
                          "endpoint": lg.S3_ENDPOINT, "sts-endpoint": "http://sts:9000", "path-style-access": True,
                          "flavor": "s3-compat", "sts-enabled": True, "sts-token-validity-seconds": 900},
      "storage-credential": {"type": "s3", "credential-type": "access-key",
                             "aws-access-key-id": "lakekeeper", "aws-secret-access-key": "lakekeeper-secret-key"}}
r = requests.post(f"{LK}/management/v1/warehouse", json=wh, timeout=60)
out["create_warehouse"] = [r.status_code, r.text[:300]]

cat = load_catalog("lk", **{"type": "rest", "uri": f"{LK}/catalog", "warehouse": "lk",
                            "header.X-Iceberg-Access-Delegation": "vended-credentials"})
schema = pa.schema([("id", pa.int64()), ("v", pa.string())])
for ns in ("d1", "d2"):
    cat.create_namespace_if_not_exists(ns)
tabs = {}
for name in ("d1.a", "d1.a_backup", "d2.b"):
    t = cat.create_table_if_not_exists(name, schema)
    t.append(pa.table({"id": [1], "v": [name]}, schema=schema))
    tabs[name] = t.location()
out["locations"] = tabs

# A table that shares a location: register_table onto d1.a's current metadata (what a migration does).
a = cat.load_table("d1.a")
try:
    reg = cat.register_table("d2.a_registered", a.metadata_location)
    out["register_table_same_location"] = {"ok": True, "location": reg.location()}
except Exception as e:
    out["register_table_same_location"] = {"ok": False, "error": f"{type(e).__name__}: {e}"[:400]}

for name in ["d1.a", "d2.b"] + (["d2.a_registered"] if out["register_table_same_location"]["ok"] else []):
    ns, tb = name.split(".")
    t0 = time.time()
    r = requests.get(f"{LK}/catalog/v1/{cat.properties.get('prefix', '')}/namespaces/{ns}/tables/{tb}",
                     headers={"X-Iceberg-Access-Delegation": "vended-credentials"}, timeout=30)
    if r.status_code == 404:  # prefix is the warehouse id from /config
        cfg = requests.get(f"{LK}/catalog/v1/config", params={"warehouse": "lk"}, timeout=30).json()
        pre = cfg["defaults"]["prefix"]
        r = requests.get(f"{LK}/catalog/v1/{pre}/namespaces/{ns}/tables/{tb}",
                         headers={"X-Iceberg-Access-Delegation": "vended-credentials"}, timeout=30)
    lt = r.json()
    vc = lg.vended_config(lt)
    exp = vc.get("s3.session-token-expires-at-ms")
    out[f"loadTable {name}"] = {"status": r.status_code, "latency_ms": round((time.time() - t0) * 1000),
                                "config_keys": sorted(lt.get("config", {})),
                                "storage_credentials_prefixes": [c["prefix"] for c in lt.get("storage-credentials", []) or []],
                                "expires_in_s": round(int(exp) / 1000 - time.time()) if exp else None,
                                "refresh_endpoint": vc.get("client.refresh-credentials-endpoint")}
    lg.save_state(f"lk-{name}.json", vc)
lg.save_state("lk-locations.json", tabs)
pre = requests.get(f"{LK}/catalog/v1/config", params={"warehouse": "lk"}, timeout=30).json()["defaults"]["prefix"]
rc = requests.get(f"{LK}/catalog/v1/{pre}/namespaces/d1/tables/a/credentials", timeout=30)
out["credentials_endpoint"] = [rc.status_code, list(rc.json()) if rc.ok else rc.text[:300]]
print(json.dumps(out, indent=2))
json.dump(out, open("/lab/results/lakekeeper/probe.json", "w"), indent=2)
