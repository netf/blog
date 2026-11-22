"""Blast radius of one stolen Spark job credential, per arm (runs in the py container).

Two thefts:
  s3_key        only the storage key (a log line, a config dump, a packet capture)
  fileio_bag    everything Spark serializes into a task's FileIO, which includes the catalog
                `credential` (client_id:secret) next to the S3 key (escape/spark_fileio_props.py)
For each: how many of the lake's 300 tables can be read, and for how long the thing keeps working.
Writes results/escape/blast-radius-<arm>.json and state/stolen-<arm>.json (for the lifetime test)."""
import json, sys, time
import requests
import lg
from escape import scan

JOB_TABLE = ("ops", "src_spark_61")
ARM = {"a": ("lake_a", "b"), "b": ("lake_b", "b"), "c": ("lake_c", "c")}


def main(arm):
    cat, inst = ARM[arm]
    cid, secret = lg.load_state("principals.json")[arm]["spark"]
    locs = [f"s3://{lg.BUCKET}/{cat}/{ns}/{t}" for ns, t in lg.lake_tables()]
    out = {"arm": arm, "catalog": cat, "tables_in_lake": len(locs)}
    if arm == "a":
        key = {"s3.access-key-id": "spark-a", "s3.secret-access-key": "spark-a-secret-key"}
    else:
        r, _ = lg.Polaris(lg.POLARIS[inst], cid, secret).load_table(cat, *JOB_TABLE)
        key = lg.vended_config(r.json())
    lg.save_state(f"stolen-{arm}.json", key)
    t0 = time.time()
    out["s3_key"] = {"tables_readable": len(scan(key, locs)),
                     "expires_in_s": round(int(key["s3.session-token-expires-at-ms"]) / 1000 - time.time())
                     if key.get("s3.session-token-expires-at-ms") else None}
    # fileio_bag: use the catalog credential to vend a key for every table, then read with it.
    pol = lg.Polaris(lg.POLARIS[inst], cid, secret)
    loaded, readable, denied = 0, 0, {}
    for ns, t in lg.lake_tables():
        r, _ = pol.load_table(cat, ns, t, vend=arm != "a")
        if r.status_code != 200:
            denied[r.status_code] = denied.get(r.status_code, 0) + 1
            continue
        loaded += 1
        k = key if arm == "a" else lg.vended_config(r.json())
        if scan(k, [f"s3://{lg.BUCKET}/{cat}/{ns}/{t}"]):
            readable += 1
    out["fileio_bag"] = {"tables_loadable": loaded, "tables_readable": readable, "load_denied_by_status": denied,
                         "credential_lifetime": "until the client secret is rotated (Polaris client secrets do not expire)"}
    out["elapsed_s"] = round(time.time() - t0)
    json.dump(out, open(f"/lab/results/escape/blast-radius-{arm}.json", "w"), indent=2)
    print(json.dumps(out))


if __name__ == "__main__":
    main(sys.argv[1])
