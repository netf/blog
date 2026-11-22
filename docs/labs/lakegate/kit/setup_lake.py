"""Creates the Polaris catalogs and the 300-table lake in each (python kit/setup_lake.py lake_a lake_b ...).
Every table gets one 10-row data file; each job source src_<engine>_<D> gets D one-row files so a job
that reads one file per minute touches S3 for its whole run."""
import sys, time
from concurrent.futures import ThreadPoolExecutor
import pyarrow as pa
from pyiceberg.catalog import load_catalog
from pyiceberg.exceptions import TableAlreadyExistsError
import lg

SCHEMA = pa.schema([("id", pa.int64()), ("v", pa.string())])


def catalog(name):
    inst, vend = lg.CATALOGS[name]
    props = {"type": "rest", "uri": f"{lg.POLARIS[inst]}/api/catalog", "warehouse": name,
             "credential": "root:s3cr3t", "scope": "PRINCIPAL_ROLE:ALL"}
    if vend:
        props["header.X-Iceberg-Access-Delegation"] = "vended-credentials"
    else:
        props.update({"header.X-Iceberg-Access-Delegation": "", "s3.endpoint": lg.S3_ENDPOINT,
                      "s3.access-key-id": "admin", "s3.secret-access-key": "password123"})
    return load_catalog(name, **props)


def build(name, only=None):
    inst, vend = lg.CATALOGS[name]
    lg.Polaris(lg.POLARIS[inst]).create_catalog(name, vend)
    cat = catalog(name)
    for d in lg.DOMAINS:
        cat.create_namespace_if_not_exists(d)
    tables = [t for t in lg.lake_tables() if only is None or t in only]
    t0 = time.time()

    def one(nt):
        ns, t = nt
        try:
            tbl = cat.create_table(f"{ns}.{t}", SCHEMA)
        except TableAlreadyExistsError:
            return
        if t.startswith("tgt_"):
            return
        if t.startswith("src_"):
            for i in range(int(t.rsplit("_", 1)[1])):
                tbl.append(pa.table({"id": [i], "v": [f"{t}-{i}"]}, schema=SCHEMA))
        else:
            tbl.append(pa.table({"id": list(range(10)), "v": [f"{ns}.{t}"] * 10}, schema=SCHEMA))

    with ThreadPoolExecutor(8) as ex:
        list(ex.map(one, tables))
    print(f"{name}: {len(tables)} tables in {time.time() - t0:.0f}s", flush=True)


if __name__ == "__main__":
    with ThreadPoolExecutor(4) as ex:
        list(ex.map(build, sys.argv[1:]))
