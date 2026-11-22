"""Creates one catalog principal per engine per arm and writes the Trino catalog files.

Arm A and B principals get catalog-wide TABLE_WRITE_DATA, which is what "the engine's service
principal" usually looks like. Arm C principals start with no grants: kit/grants.py fills them
from the audit-log inventory."""
import os
import lg

TRINO_DIR = os.path.join(lg.LAB, "config/trino/catalog")
ARMS = {"a": ("lake_a", "b"), "b": ("lake_b", "b"), "c": ("lake_c", "c"), "f": ("lake_f", "f")}


def trino_catalog(arm, cid, secret):
    cat, inst = ARMS[arm]
    lines = ["connector.name=iceberg", "iceberg.catalog.type=rest",
             f"iceberg.rest-catalog.uri={lg.POLARIS[inst]}/api/catalog", f"iceberg.rest-catalog.warehouse={cat}",
             "iceberg.rest-catalog.security=OAUTH2", f"iceberg.rest-catalog.oauth2.credential={cid}:{secret}",
             "iceberg.rest-catalog.oauth2.scope=PRINCIPAL_ROLE:ALL",
             "fs.native-s3.enabled=true", f"s3.endpoint={lg.S3_ENDPOINT}", "s3.region=us-east-1", "s3.path-style-access=true"]
    if arm == "a":
        lines += ["s3.aws-access-key=trino-a", "s3.aws-secret-key=trino-a-secret-key"]
    else:
        lines += ["iceberg.rest-catalog.vended-credentials-enabled=true"]
    with open(os.path.join(TRINO_DIR, f"{arm}.properties"), "w") as f:
        f.write("\n".join(lines) + "\n")


def main():
    out = {}
    for arm, (cat, inst) in ARMS.items():
        p = lg.Polaris(lg.POLARIS[inst])
        out[arm] = {}
        for e in lg.ENGINES:
            name = f"{e}_{arm}"
            cid, secret = p.principal(name)
            p.role_for(name, cat, f"r_{name}")
            if arm != "c":
                p.grant(cat, f"r_{name}", {"type": "catalog", "privilege": "TABLE_WRITE_DATA"})
                # DuckDB commits through POST /transactions/commit, which Polaris authorizes
                # with TABLE_WRITE_PROPERTIES + TABLE_CREATE.
                p.grant(cat, f"r_{name}", {"type": "catalog", "privilege": "TABLE_CREATE"})
            out[arm][e] = [cid, secret]
            if e == "trino":
                trino_catalog(arm, cid, secret)
    lg.save_state("principals.json", out)
    print("principals:", {a: list(v) for a, v in out.items()})


if __name__ == "__main__":
    main()
