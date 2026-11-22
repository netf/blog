"""Creates <ns>.<name>_src (N one-row files) and <ns>.<name>_tgt (empty) for failure tests.
python kit/mk_tables.py <arm f|lk> <ns> <files> <name> [<name> ...]"""
import sys
import pyarrow as pa
from pyiceberg.catalog import load_catalog
from pyiceberg.exceptions import TableAlreadyExistsError
import lg

SCHEMA = pa.schema([("id", pa.int64()), ("v", pa.string())])


def root_catalog(arm):
    if arm == "lk":
        return load_catalog("lk", **{"type": "rest", "uri": "http://lakekeeper:8181/catalog", "warehouse": "lk",
                                     "header.X-Iceberg-Access-Delegation": "vended-credentials"})
    cat, inst = {"f": ("lake_f", "f"), "c": ("lake_c", "c")}[arm]
    return load_catalog(cat, **{"type": "rest", "uri": f"{lg.POLARIS[inst]}/api/catalog", "warehouse": cat,
                                "credential": "root:s3cr3t", "scope": "PRINCIPAL_ROLE:ALL",
                                "header.X-Iceberg-Access-Delegation": "vended-credentials"})


if __name__ == "__main__":
    arm, ns, n, names = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4:]
    cat = root_catalog(arm)
    cat.create_namespace_if_not_exists(ns)
    for name in names:
        try:
            src = cat.create_table(f"{ns}.{name}_src", SCHEMA)
            for i in range(n):
                src.append(pa.table({"id": [i], "v": [f"{name}-{i}"]}, schema=SCHEMA))
            cat.create_table(f"{ns}.{name}_tgt", SCHEMA)
        except TableAlreadyExistsError:
            pass
    print("ok", arm, ns, names)
