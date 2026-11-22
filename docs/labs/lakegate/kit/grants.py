"""Migration kit step 2: catalog roles and grants generated from the inventory.

python kit/grants.py --catalog lake_c --instance c [--apply]
One catalog role per engine key (r_<engine>_c): TABLE_READ_DATA on every table the key only
read, TABLE_WRITE_DATA on every table it wrote. DuckDB writers also need TABLE_CREATE on the
namespace plus TABLE_WRITE_PROPERTIES, because DuckDB commits through POST /transactions/commit
(Polaris authorizes COMMIT_TRANSACTION with both); the plan flags that as an over-grant."""
import argparse, json, os
import lg

TX_COMMIT_ENGINES = {"duckdb"}


def plan(inventory, engines):
    out = {}
    for e in engines:
        k = inventory["keys"].get(f"{e}-a")
        if not k:
            continue
        grants, flags = [], []
        for t in k["tables_read"]:
            ns, tb = t.split(".")
            grants.append({"type": "table", "namespace": [ns], "tableName": tb, "privilege": "TABLE_READ_DATA"})
        for t in k["tables_written"]:
            ns, tb = t.split(".")
            grants.append({"type": "table", "namespace": [ns], "tableName": tb, "privilege": "TABLE_WRITE_DATA"})
            if e in TX_COMMIT_ENGINES:
                grants.append({"type": "table", "namespace": [ns], "tableName": tb, "privilege": "TABLE_WRITE_PROPERTIES"})
        if e in TX_COMMIT_ENGINES and k["tables_written"]:
            for ns in sorted({t.split(".")[0] for t in k["tables_written"]}):
                grants.append({"type": "namespace", "namespace": [ns], "privilege": "TABLE_CREATE"})
                flags.append(f"TABLE_CREATE on namespace {ns}: needed for DuckDB's multi-table commit endpoint, "
                             "lets this principal create tables there")
        out[e] = {"role": f"r_{e}_c", "grants": grants, "flags": flags,
                  "tables_readable": len(k["tables_read"]) + len(k["tables_written"])}
    return out


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--catalog", default="lake_c")
    p.add_argument("--instance", default="c")
    p.add_argument("--apply", action="store_true")
    a = p.parse_args()
    inv = json.load(open(os.path.join(lg.LAB, "results/kit/inventory.json")))
    pl = plan(inv, lg.ENGINES)
    json.dump(pl, open(os.path.join(lg.LAB, "results/kit/grants-plan.json"), "w"), indent=2)
    for e, v in pl.items():
        print(f"{e:10s} role={v['role']} grants={len(v['grants'])} tables={v['tables_readable']} flags={v['flags']}")
    if a.apply:
        pol = lg.Polaris(lg.POLARIS[a.instance])
        for e, v in pl.items():
            role = v["role"].replace("_c", f"_{a.instance}") if a.instance != "c" else v["role"]
            for g in v["grants"]:
                pol.grant(a.catalog, role, g)
        print("applied")
