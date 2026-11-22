"""Shared constants and helpers for the lakegate lab (Polaris admin API, S3 clients, lake layout)."""
import json, os, time
import boto3, requests
from botocore.config import Config

LAB = os.environ.get("LAB", "/lab")
STATE = os.path.join(LAB, "state")
S3_ENDPOINT = os.environ.get("S3_ENDPOINT", "http://minio:9000")
BUCKET = "lake"

DOMAINS = ["sales", "finance", "marketing", "ops", "hr", "product"]
TABLES_PER_DOMAIN = 50
ENGINES = ["spark", "trino", "pyiceberg", "duckdb"]
DURATIONS = [5, 30, 61, 120]

# Observation workload ("what each engine's jobs read") that the migration kit must recover
# from the audit log alone. Each engine also reads its src_* and writes its tgt_* tables.
SWEEPS = {
    "spark": [("sales", i) for i in range(20)] + [("finance", i) for i in range(10)],
    "trino": [("marketing", i) for i in range(15)] + [("sales", i) for i in range(5)],
    "pyiceberg": [("product", i) for i in range(10)],
    "duckdb": [("hr", i) for i in range(5)],
}

# LG_POLARIS_<B|C|F> lets host-side tools reach the published ports instead of Compose names.
POLARIS = {k: os.environ.get(f"LG_POLARIS_{k.upper()}", f"http://polaris-{k}:8181") for k in ("b", "c", "f")}
# catalog name -> (polaris instance, vends credentials)
CATALOGS = {"lake_a": ("b", False), "lake_b": ("b", True), "lake_c": ("c", True), "lake_f": ("f", True)}


def job_tables(engine, dur):
    return f"src_{engine}_{dur}", f"tgt_{engine}_{dur}"


def lake_tables():
    """All 300 (namespace, table) pairs of one lake."""
    out = []
    for d in DOMAINS:
        if d == "ops":
            jt = [t for e in ENGINES for dur in DURATIONS for t in job_tables(e, dur)]
            out += [(d, t) for t in jt] + [(d, f"t{i:03d}") for i in range(TABLES_PER_DOMAIN - len(jt))]
        else:
            out += [(d, f"t{i:03d}") for i in range(TABLES_PER_DOMAIN)]
    return out


def s3(ak="admin", sk="password123", st=None, endpoint=S3_ENDPOINT):
    return boto3.client("s3", endpoint_url=endpoint, aws_access_key_id=ak, aws_secret_access_key=sk,
                        aws_session_token=st, region_name="us-east-1",
                        config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 1},
                                      connect_timeout=5, read_timeout=30))


class Polaris:
    def __init__(self, base, client_id="root", secret="s3cr3t"):
        self.base = base
        self.client_id, self.secret = client_id, secret
        self._tok, self._tok_at = None, 0

    def token(self):
        if not self._tok or time.time() - self._tok_at > 1800:
            r = requests.post(f"{self.base}/api/catalog/v1/oauth/tokens", data={
                "grant_type": "client_credentials", "client_id": self.client_id,
                "client_secret": self.secret, "scope": "PRINCIPAL_ROLE:ALL"}, timeout=30)
            r.raise_for_status()
            self._tok, self._tok_at = r.json()["access_token"], time.time()
        return self._tok

    def h(self, **extra):
        return {"Authorization": f"Bearer {self.token()}", **extra}

    def mgmt(self, method, path, body=None, ok=(200, 201, 204, 409)):
        r = requests.request(method, f"{self.base}/api/management/v1/{path}", headers=self.h(), json=body, timeout=30)
        if r.status_code not in ok:
            raise RuntimeError(f"{method} {path} -> {r.status_code} {r.text[:400]}")
        return r.json() if r.text and r.status_code != 204 else {}

    def create_catalog(self, name, vend, props=None):
        sci = {"storageType": "S3", "allowedLocations": [f"s3://{BUCKET}/{name}"],
               "roleArn": "arn:aws:iam::000000000000:role/lakegate", "endpoint": S3_ENDPOINT,
               "stsEndpoint": "http://sts:9000", "pathStyleAccess": True, "region": "us-east-1",
               # Without this Polaris adds a kms:* statement that MinIO STS rejects (preflight).
               "kmsUnavailable": True}
        if not vend:
            sci["stsUnavailable"] = True
        self.mgmt("POST", "catalogs", {"catalog": {"name": name, "type": "INTERNAL",
                  "properties": {"default-base-location": f"s3://{BUCKET}/{name}", **(props or {})}, "storageConfigInfo": sci}})
        self.mgmt("PUT", f"principal-roles/service_admin/catalog-roles/{name}", {"catalogRole": {"name": "catalog_admin"}})
        self.grant(name, "catalog_admin", {"type": "catalog", "privilege": "TABLE_WRITE_DATA"})

    def principal(self, name):
        """Creates (or rotates) a principal and returns (client_id, client_secret)."""
        r = requests.post(f"{self.base}/api/management/v1/principals", headers=self.h(),
                          json={"principal": {"name": name}}, timeout=30)
        if r.status_code == 409:
            r = requests.post(f"{self.base}/api/management/v1/principals/{name}/rotate", headers=self.h(), timeout=30)
        r.raise_for_status()
        c = r.json()["credentials"]
        return c["clientId"], c["clientSecret"]

    def role_for(self, principal, catalog, role):
        self.mgmt("POST", "principal-roles", {"principalRole": {"name": role}})
        self.mgmt("PUT", f"principals/{principal}/principal-roles", {"principalRole": {"name": role}})
        self.mgmt("POST", f"catalogs/{catalog}/catalog-roles", {"catalogRole": {"name": role}})
        self.mgmt("PUT", f"principal-roles/{role}/catalog-roles/{catalog}", {"catalogRole": {"name": role}})

    def grant(self, catalog, role, grant):
        self.mgmt("PUT", f"catalogs/{catalog}/catalog-roles/{role}/grants", {"grant": grant})

    def revoke(self, catalog, role, grant):
        self.mgmt("POST", f"catalogs/{catalog}/catalog-roles/{role}/grants?cascade=false", {"grant": grant}, ok=(200, 201, 204, 404))

    def load_table(self, catalog, ns, table, vend=True):
        hdr = {"X-Iceberg-Access-Delegation": "vended-credentials"} if vend else {}
        t0 = time.time()
        r = requests.get(f"{self.base}/api/catalog/v1/{catalog}/namespaces/{ns}/tables/{table}", headers=self.h(**hdr), timeout=60)
        return r, time.time() - t0


def vended_config(load_table_json):
    """Merges the table-level config with the first storage-credentials entry, as clients do."""
    cfg = dict(load_table_json.get("config", {}))
    for c in load_table_json.get("storage-credentials", []) or []:
        cfg.update(c["config"])
        break
    return cfg


def save_state(name, obj):
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, name), "w") as f:
        json.dump(obj, f, indent=2)


def load_state(name):
    with open(os.path.join(STATE, name)) as f:
        return json.load(f)
