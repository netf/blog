"""Files under a table's location that no committed metadata references (runs in the py container).
python kit/orphans.py <arm f|c> <ns.table> [...]  -> JSON per table"""
import json, sys
import lg
from mk_tables import root_catalog


def referenced(t):
    io = t.io
    refs = {t.metadata_location}
    refs |= {e.metadata_file for e in t.metadata.metadata_log}
    for s in t.snapshots():
        refs.add(s.manifest_list)
        for m in s.manifests(io):
            refs.add(m.manifest_path)
            for e in m.fetch_manifest_entry(io, discard_deleted=False):
                refs.add(e.data_file.file_path)
    return {r.split(f"s3://{lg.BUCKET}/", 1)[1] for r in refs}


arm = sys.argv[1]
cat = root_catalog(arm)
admin = lg.s3()
out = {}
for name in sys.argv[2:]:
    t = cat.load_table(name)
    prefix = t.location().split(f"s3://{lg.BUCKET}/", 1)[1] + "/"
    listed = set()
    for page in admin.get_paginator("list_objects_v2").paginate(Bucket=lg.BUCKET, Prefix=prefix):
        listed |= {o["Key"] for o in page.get("Contents", [])}
    refs = referenced(t)
    orphans = sorted(listed - refs)
    out[name] = {"objects": len(listed), "referenced": len(listed & refs), "orphans": len(orphans),
                 "orphan_data_files": sum(o.endswith(".parquet") for o in orphans),
                 "orphan_manifests": sum(o.endswith(".avro") for o in orphans),
                 "committed_snapshots": len(t.snapshots()), "sample": orphans[:3]}
print(json.dumps(out, indent=2))
