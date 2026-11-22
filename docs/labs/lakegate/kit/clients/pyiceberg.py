# PyIceberg 0.12.0 never calls the refresh endpoint. Either keep jobs shorter than the TTL
# (minus the 5-minute margin), or wrap each table's FileIO with lakegate_client.refreshing().
from pyiceberg.catalog import load_catalog
from lakegate_client import refreshing

cat = load_catalog("lake", **{
    "type": "rest",
    "uri": "http://polaris:8181/api/catalog",
    "warehouse": "lake_c",
    "credential": "<client_id>:<client_secret>",
    "scope": "PRINCIPAL_ROLE:ALL",
    "header.X-Iceberg-Access-Delegation": "vended-credentials",
})
src = refreshing(cat, cat.load_table("ops.src"))
tgt = refreshing(cat, cat.load_table("ops.tgt"))
