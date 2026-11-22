"""When do a table's vended credentials reach another table's files? (Polaris, scratch catalog lake_x)

1 sibling      x.a and x.a_backup: does a's key read a_backup? (prefix policy ends in "a/*")
2 rename       x.r renamed to x.r_old (files stay at .../x/r), then a new x.r is created at the
               default location .../x/r: do the two tables now share a prefix?
3 register     register_table x.reg from x.a's metadata file (what a migration does)
4 explicit     create x.ov with location = x.a's location, and x.nest under it
python escape/location_tests.py [overlap]   ("overlap": catalog lake_y with
polaris.config.allow.overlapping.table.location=true, the switch migrations flip)
Writes results/escape/locations[-overlap].json."""
import json, sys
import pyarrow as pa
from pyiceberg.catalog import load_catalog
import lg
from escape import attempt, vended_client, sample_files

OVERLAP = sys.argv[1:] == ["overlap"]
INST, CAT = "f", ("lake_y" if OVERLAP else "lake_x")
SCHEMA = pa.schema([("id", pa.int64()), ("v", pa.string())])
pol = lg.Polaris(lg.POLARIS[INST])
pol.create_catalog(CAT, True, {"polaris.config.allow.overlapping.table.location": "true"} if OVERLAP else None)
cat = load_catalog(CAT, **{"type": "rest", "uri": f"{lg.POLARIS[INST]}/api/catalog", "warehouse": CAT,
                           "credential": "root:s3cr3t", "scope": "PRINCIPAL_ROLE:ALL",
                           "header.X-Iceberg-Access-Delegation": "vended-credentials"})
cat.create_namespace_if_not_exists("x")
admin = lg.s3()
out = {}


def mk(name, **kw):
    try:
        t = cat.create_table(f"x.{name}", SCHEMA, **kw)
        t.append(pa.table({"id": [1], "v": [name]}, schema=SCHEMA))
        return {"created": True, "location": t.location()}
    except Exception as e:
        return {"created": False, "error": f"{type(e).__name__}: {e}"[:300]}


def key_for(name):
    r, _ = pol.load_table(CAT, "x", name)
    return lg.vended_config(r.json()) if r.status_code == 200 else None


def reads(name, other_location):
    k = key_for(name)
    f = sample_files(admin, other_location)
    v = vended_client(k)
    return {kind: attempt(lambda key=key: len(v.get_object(Bucket=lg.BUCKET, Key=key)["Body"].read()))["allowed"]
            for kind, key in f.items() if key}


def writes(name, other_location):
    k = key_for(name)
    v = vended_client(k)
    key = other_location.split(f"s3://{lg.BUCKET}/", 1)[1] + "/data/lakegate-escape.txt"
    r = attempt(lambda: v.put_object(Bucket=lg.BUCKET, Key=key, Body=b"x")["ResponseMetadata"]["HTTPStatusCode"])
    if r["allowed"]:
        admin.delete_object(Bucket=lg.BUCKET, Key=key)
    return r["allowed"]


a = mk("a")
b = mk("a_backup")
out["1_sibling"] = {"a": a, "a_backup": b, "a_key_reads_a_backup": reads("a", b["location"])}

r = mk("r")
cat.rename_table("x.r", "x.r_old")
r_old_loc = cat.load_table("x.r_old").location()
r2 = mk("r")
res = {"r_old_location": r_old_loc, "new_r": r2}
if r2["created"]:
    res["shared_prefix"] = r2["location"] == r_old_loc
    res["new_r_key_reads_r_old"] = reads("r", r_old_loc)
    res["new_r_key_writes_into_r_old"] = writes("r", r_old_loc)
out["2_rename_then_recreate"] = res

ta = cat.load_table("x.a")
try:
    reg = cat.register_table("x.reg", ta.metadata_location)
    out["3_register_table"] = {"registered": True, "location": reg.location(),
                               "reg_key_reads_a": reads("reg", ta.location()),
                               "reg_key_writes_into_a": writes("reg", ta.location())}
except Exception as e:
    out["3_register_table"] = {"registered": False, "error": f"{type(e).__name__}: {e}"[:300]}

out["4_explicit_same_location"] = mk("ov", location=ta.location())
out["4_explicit_nested_location"] = mk("nest", location=ta.location() + "/nested")
json.dump(out, open(f"/lab/results/escape/locations{'-overlap' if OVERLAP else ''}.json", "w"), indent=2)
print(json.dumps(out, indent=2))
