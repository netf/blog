"""Preflight probe: Polaris 1.9.0 + MinIO STS. Records what loadTable returns and whether the
vended key is scoped to the table prefix. Not a measurement; run against the stand-in MinIO."""
import json, sys, time, uuid
import boto3, botocore, requests
from botocore.config import Config
from pyiceberg.catalog import load_catalog
import pyarrow as pa

P = "http://localhost:8181"
S3 = "http://localhost:9000"
out = {}

def s3(ak, sk, st=None):
    return boto3.client("s3", endpoint_url=S3, aws_access_key_id=ak, aws_secret_access_key=sk,
                        aws_session_token=st, region_name="us-east-1",
                        config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 1}))

root = s3("admin", "password123")
try:
    root.create_bucket(Bucket="lake")
except root.exceptions.BucketAlreadyOwnedByYou:
    pass

tok = requests.post(f"{P}/api/catalog/v1/oauth/tokens", data={
    "grant_type": "client_credentials", "client_id": "root", "client_secret": "s3cr3t",
    "scope": "PRINCIPAL_ROLE:ALL"}).json()["access_token"]
H = {"Authorization": f"Bearer {tok}"}
r = requests.post(f"{P}/api/management/v1/catalogs", headers=H, json={"catalog": {
    "name": "lake", "type": "INTERNAL", "properties": {"default-base-location": "s3://lake/wh"},
    "storageConfigInfo": {"storageType": "S3", "allowedLocations": ["s3://lake/wh"],
        "roleArn": "arn:aws:iam::000000000000:role/lakegate", "endpoint": "http://minio:9000",
        "stsEndpoint": "http://minio:9000", "pathStyleAccess": True, "region": "us-east-1",
        # Polaris adds a kms:* statement to the session policy unless told KMS is absent;
        # MinIO STS rejects it: invalid resource 'arn:aws:kms:us-east-1:000000000000:key/*'
        "kmsUnavailable": True}}})
out["create_catalog"] = [r.status_code, r.text[:300]]
# root principal role -> catalog_admin on the new catalog
requests.put(f"{P}/api/management/v1/principal-roles/service_admin/catalog-roles/lake", headers=H,
             json={"catalogRole": {"name": "catalog_admin"}})
# CATALOG_MANAGE_CONTENT alone is refused for CREATE_TABLE_DIRECT_WITH_WRITE_DELEGATION
requests.put(f"{P}/api/management/v1/catalogs/lake/catalog-roles/catalog_admin/grants", headers=H,
             json={"grant": {"type": "catalog", "privilege": "TABLE_WRITE_DATA"}})

cat = load_catalog("p", **{"type": "rest", "uri": f"{P}/api/catalog", "warehouse": "lake",
    "credential": "root:s3cr3t", "scope": "PRINCIPAL_ROLE:ALL",
    "header.X-Iceberg-Access-Delegation": "vended-credentials", "s3.endpoint": S3})
for ns in ("d1", "d2"):
    cat.create_namespace_if_not_exists(ns)
schema = pa.schema([("id", pa.int64())])
ta = cat.create_table_if_not_exists("d1.a", schema)
tb = cat.create_table_if_not_exists("d2.b", schema)
ta.append(pa.table({"id": [1, 2]})); tb.append(pa.table({"id": [3]}))

lt = requests.get(f"{P}/api/catalog/v1/lake/namespaces/d1/tables/a", headers={**H,
    "X-Iceberg-Access-Delegation": "vended-credentials"}).json()
cfg = lt.get("config", {})
out["loadTable_config_keys"] = sorted(cfg)
out["storage_credentials"] = [{"prefix": c["prefix"], "keys": sorted(c["config"])} for c in lt.get("storage-credentials", [])]
creds = (lt.get("storage-credentials") or [{"config": cfg}])[0]["config"] | cfg
exp = creds.get("s3.session-token-expires-at-ms")
out["expires_in_s"] = (int(exp) / 1000 - time.time()) if exp else None
out["refresh_endpoint"] = creds.get("client.refresh-credentials-endpoint")
rc = requests.get(f"{P}/api/catalog/v1/lake/namespaces/d1/tables/a/credentials", headers=H)
out["credentials_endpoint"] = [rc.status_code, list(rc.json()) if rc.ok else rc.text[:200]]

v = s3(creds["s3.access-key-id"], creds["s3.secret-access-key"], creds.get("s3.session-token"))
def tryit(name, fn):
    try:
        res = fn(); out[name] = "ALLOWED " + str(res)[:120]
    except botocore.exceptions.ClientError as e:
        out[name] = "DENIED " + e.response["Error"]["Code"]
loc_a = ta.location().replace("s3://lake/", ""); loc_b = tb.location().replace("s3://lake/", "")
tryit("list_own_prefix", lambda: [o["Key"] for o in v.list_objects_v2(Bucket="lake", Prefix=loc_a + "/").get("Contents", [])][:2])
tryit("list_other_prefix", lambda: len(v.list_objects_v2(Bucket="lake", Prefix=loc_b + "/").get("Contents", [])))
tryit("list_bucket_root", lambda: len(v.list_objects_v2(Bucket="lake").get("Contents", [])))
other = [o["Key"] for o in root.list_objects_v2(Bucket="lake", Prefix=loc_b + "/data/")["Contents"]][0]
tryit("read_other_table_data", lambda: len(v.get_object(Bucket="lake", Key=other)["Body"].read()))
tryit("write_outside", lambda: v.put_object(Bucket="lake", Key="elsewhere/x", Body=b"x")["ResponseMetadata"]["HTTPStatusCode"])
out["table_a_location"] = ta.location(); out["table_b_location"] = tb.location()
json.dump(out, sys.stdout, indent=2); print()
