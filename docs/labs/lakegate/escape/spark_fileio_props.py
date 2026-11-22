"""What does a Spark job's table FileIO carry? Prints the property keys (values redacted except
for non-secret ones) of the FileIO that Spark serializes into tasks, for one arm.
jobs/spark-submit.sh escape/spark_fileio_props.py --arm b"""
import argparse, json, sys
sys.path.insert(0, "/lab/jobs")
sys.path.insert(0, "/lab/kit")
import lg
from spark_jobs import session

SAFE = ("uri", "endpoint", "region", "expires", "path-style", "refresh-credentials", "warehouse", "prefix", "scope", "header", "enabled")

p = argparse.ArgumentParser()
p.add_argument("--arm", required=True)
p.add_argument("--table", default="ops.src_spark_5")
a = p.parse_args()
principal = lg.load_state("principals.json")[a.arm]["spark"]
spark = session(a.arm, principal, [])
jvm = spark._jvm
cat = spark._jsparkSession.sessionState().catalogManager().catalog("lg")
ns, tb = a.table.split(".")
arr = spark.sparkContext._gateway.new_array(jvm.java.lang.String, 1)
arr[0] = ns
ident = jvm.org.apache.spark.sql.connector.catalog.Identifier.of(arr, tb)
table = cat.loadTable(ident).table()
ser = jvm.org.apache.iceberg.spark.source.SerializableTableWithSize.copyOf(table)
props = dict(ser.io().properties())
out = {k: (v if any(s in k for s in SAFE) else f"<redacted, {len(v)} chars>") for k, v in sorted(props.items())}
same = props.get("credential") == f"{principal[0]}:{principal[1]}"
print("FILEIO_PROPS " + json.dumps({"arm": a.arm, "table": a.table, "io_class": ser.io().getClass().getName(),
                                    "credential_is_the_principal_client_id_and_secret": same, "props": out}))
spark.stop()
