"""Migration kit step 1: inventory of bucket keys -> tables, from the MinIO audit log alone.

python3 kit/inventory.py results/audit/audit.jsonl state/observe-window.json [results/observe/jobs.jsonl]
Writes results/kit/inventory.json. With a job manifest (start/end per job) it also tries to
attribute requests to jobs and reports how many jobs it could not separate from others that
shared the same key at the same time."""
import collections, json, sys
from datetime import datetime

READ = {"GetObject", "HeadObject", "ListObjectsV2", "ListObjectsV1", "GetObjectAttributes"}
WRITE = {"PutObject", "NewMultipartUpload", "PutObjectPart", "CompleteMultipartUpload", "DeleteObject",
         "DeleteMultipleObjects", "CopyObject", "AbortMultipartUpload"}


def ts(s):
    """All timestamps here are UTC ISO-8601; millisecond precision is enough."""
    return datetime.fromisoformat(s[:23] + "+00:00")


def table_of(obj):
    """lake_a/<ns>/<table>/(data|metadata)/... -> (catalog_prefix, ns, table)"""
    parts = obj.split("/")
    if len(parts) >= 4 and parts[3] in ("data", "metadata"):
        return parts[0], parts[1], parts[2]
    return None


def main(audit_path, window_path, manifest_path=None):
    w = json.load(open(window_path))
    start, end = ts(w["start"]), ts(w["end"])
    keys = collections.defaultdict(lambda: {"read": collections.Counter(), "write": collections.Counter(),
                                            "other_paths": collections.Counter(), "user_agents": collections.Counter(),
                                            "first": None, "last": None})
    events = []
    for line in open(audit_path):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        t = ts(r["time"])
        if not (start <= t <= end):
            continue
        ak = r.get("accessKey") or ""
        parent = r.get("parentUser") or ""
        if parent:  # STS session keys are attributed to the user that assumed the role
            ak = f"{parent} (sts)"
        api = r["api"]
        obj = api.get("object", "")
        k = keys[ak]
        k["first"] = k["first"] or r["time"]
        k["last"] = r["time"]
        k["user_agents"][(r.get("userAgent") or "").split(" ")[0][:60]] += 1
        tb = table_of(obj) if obj else None
        if tb is None:
            k["other_paths"][api["name"]] += 1
            continue
        name = f"{tb[1]}.{tb[2]}"
        if api["name"] in READ:
            k["read"][name] += 1
        elif api["name"] in WRITE:
            k["write"][name] += 1
        events.append((t, ak, name))
    inv = {}
    for ak, k in sorted(keys.items()):
        inv[ak] = {"tables_read": sorted(set(k["read"]) - set(k["write"])), "tables_written": sorted(k["write"]),
                   "tables_touched": len(set(k["read"]) | set(k["write"])), "requests": sum(k["read"].values()) + sum(k["write"].values()),
                   "non_table_requests": dict(k["other_paths"]), "user_agents": dict(k["user_agents"].most_common(3)),
                   "first_seen": k["first"], "last_seen": k["last"]}
    out = {"window": w, "keys": inv}
    if manifest_path:
        jobs = [json.loads(l) for l in open(manifest_path)]
        jobs = [j for j in jobs if j.get("ok") and start <= ts(j["start"]) <= end]
        attributed = {}
        for j in jobs:
            key = f"{j['engine']}-a"
            js, je = ts(j["start"]), ts(j["end"])
            overlapping = [o["job"] for o in jobs if o is not j and o["engine"] == j["engine"]
                           and ts(o["start"]) < je and ts(o["end"]) > js]
            tables = sorted({n for t, ak, n in events if ak == key and js <= t <= je})
            attributed[j["job"]] = {"tables_in_window": tables, "overlapping_jobs_on_same_key": overlapping,
                                    "separable": not overlapping}
        out["jobs"] = attributed
        out["jobs_separable"] = sum(a["separable"] for a in attributed.values())
        out["jobs_total"] = len(attributed)
    json.dump(out, open("results/kit/inventory.json", "w"), indent=2)
    for ak, v in inv.items():
        print(f"{ak:22s} touched={v['tables_touched']:3d} read_only={len(v['tables_read']):3d} written={len(v['tables_written']):3d} requests={v['requests']}")
    if manifest_path:
        print(f"jobs separable by time window: {out['jobs_separable']}/{out['jobs_total']}")


if __name__ == "__main__":
    main(*sys.argv[1:])
