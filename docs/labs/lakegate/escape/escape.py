"""lakegate escape tester.

Given the storage credentials a catalog vended for ONE table, try to step outside that table:
list other prefixes, read another table's data and metadata files, write and delete elsewhere,
mint a MinIO service account, and (optionally) reuse the key after expiry or from another
container. Ground truth (which files exist) comes from the admin key; the vended key is the
only thing used for the attempts.

As a library: run_escape(cfg, own_location, other_locations) -> dict
As a CLI (scan mode): python escape/escape.py scan --cfg cfg.json --locations locs.json --out x.json
"""
import argparse, json, subprocess, sys, time, uuid
import botocore
sys.path.insert(0, "/lab/kit")
import lg


def key_of(loc):
    return loc.split(f"s3://{lg.BUCKET}/", 1)[1].rstrip("/")


def vended_client(cfg):
    return lg.s3(cfg["s3.access-key-id"], cfg["s3.secret-access-key"], cfg.get("s3.session-token"))


def attempt(fn):
    try:
        res = fn()
        return {"allowed": True, "detail": str(res)[:160]}
    except botocore.exceptions.ClientError as e:
        return {"allowed": False, "detail": e.response["Error"]["Code"]}
    except botocore.exceptions.BotoCoreError as e:
        return {"allowed": False, "detail": type(e).__name__}


def sample_files(admin, loc):
    """One data file and one metadata file under a table location (admin view)."""
    out = {}
    for kind in ("data", "metadata"):
        r = admin.list_objects_v2(Bucket=lg.BUCKET, Prefix=f"{key_of(loc)}/{kind}/", MaxKeys=5)
        keys = [o["Key"] for o in r.get("Contents", [])]
        out[kind] = keys[0] if keys else None
    return out


def readable(v, admin, loc):
    f = sample_files(admin, loc)
    res = {}
    for kind, k in f.items():
        res[f"read_{kind}"] = attempt(lambda k=k: len(v.get_object(Bucket=lg.BUCKET, Key=k)["Body"].read())) if k else {"allowed": None, "detail": "no file"}
    res["list"] = attempt(lambda: v.list_objects_v2(Bucket=lg.BUCKET, Prefix=key_of(loc) + "/", MaxKeys=2).get("KeyCount"))
    return res


def run_escape(cfg, own_location, other_locations, write_expected=False):
    admin = lg.s3()
    v = vended_client(cfg)
    own = key_of(own_location)
    out = {"own_location": own_location, "expires_in_s": None}
    exp = cfg.get("s3.session-token-expires-at-ms")
    if exp:
        out["expires_in_s"] = round(int(exp) / 1000 - time.time())
    out["own"] = readable(v, admin, own_location)
    probe = f"{own}/data/lakegate-escape-{uuid.uuid4().hex[:8]}.txt"
    out["own"]["write"] = attempt(lambda: v.put_object(Bucket=lg.BUCKET, Key=probe, Body=b"x")["ResponseMetadata"]["HTTPStatusCode"])
    if out["own"]["write"]["allowed"]:
        admin.delete_object(Bucket=lg.BUCKET, Key=probe)
    out["bucket_root_list"] = attempt(lambda: v.list_objects_v2(Bucket=lg.BUCKET, MaxKeys=2).get("KeyCount"))
    out["list_buckets"] = attempt(lambda: [b["Name"] for b in v.list_buckets()["Buckets"]])
    out["write_elsewhere"] = attempt(lambda: v.put_object(Bucket=lg.BUCKET, Key=f"elsewhere/{uuid.uuid4().hex[:8]}", Body=b"x")["ResponseMetadata"]["HTTPStatusCode"])
    others = {}
    for loc in other_locations:
        r = readable(v, admin, loc)
        f = sample_files(admin, loc)
        if f["data"]:
            r["delete_data"] = attempt(lambda k=f["data"]: v.delete_object(Bucket=lg.BUCKET, Key=k + ".nonexistent-probe")["ResponseMetadata"]["HTTPStatusCode"])
        r["write"] = attempt(lambda loc=loc: v.put_object(Bucket=lg.BUCKET, Key=f"{key_of(loc)}/data/lakegate-escape.txt", Body=b"x")["ResponseMetadata"]["HTTPStatusCode"])
        others[loc] = r
    out["others"] = others
    out["others_readable"] = sorted(l for l, r in others.items() if r["read_data"]["allowed"] or r["read_metadata"]["allowed"])
    out["svcacct_create"] = svcacct(cfg)
    return out


def svcacct(cfg):
    """CVE-2025-62506 regression: can a session-policy-restricted STS key mint a service account?"""
    host = f"http://{cfg['s3.access-key-id']}:{cfg['s3.secret-access-key']}:{cfg.get('s3.session-token', '')}@minio:9000"
    try:
        r = subprocess.run(["docker", "run", "--rm", "--network", "lakegate_default", "-e", f"MC_HOST_v={host}",
                            "cgr.dev/chainguard/minio-client:latest", "admin", "user", "svcacct", "add", "v",
                            cfg["s3.access-key-id"]], capture_output=True, text=True, timeout=60)
        txt = (r.stdout + r.stderr).strip().replace("\n", " ")
        return {"allowed": r.returncode == 0, "detail": txt[:200]}
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return {"allowed": None, "detail": f"not run here: {type(e).__name__}"}


def scan(cfg, locations):
    """Blast radius: how many of these table locations does this key read?"""
    admin = lg.s3()
    v = vended_client(cfg)
    hits = []
    for loc in locations:
        f = sample_files(admin, loc)
        k = f["data"] or f["metadata"]  # empty target tables only have metadata files
        if k and attempt(lambda: v.get_object(Bucket=lg.BUCKET, Key=k)["Body"].read(1))["allowed"]:
            hits.append(loc)
    return hits


def until_denied(cfg, loc, every_s=30, max_s=6 * 3600):
    """Reuse after expiry: keep reading one file until the key stops working."""
    admin = lg.s3()
    v = vended_client(cfg)
    k = sample_files(admin, loc)["data"]
    t0 = time.time()
    last_ok, first_denied, detail = None, None, None
    while time.time() - t0 < max_s:
        r = attempt(lambda: v.get_object(Bucket=lg.BUCKET, Key=k)["Body"].read(1))
        if r["allowed"]:
            last_ok = time.time()
        else:
            first_denied, detail = time.time(), r["detail"]
            break
        time.sleep(every_s)
    return {"issued_expires_in_s": round(int(cfg["s3.session-token-expires-at-ms"]) / 1000 - t0) if cfg.get("s3.session-token-expires-at-ms") else None,
            "last_ok_after_s": round(last_ok - t0) if last_ok else None,
            "first_denied_after_s": round(first_denied - t0) if first_denied else None, "denied_with": detail}


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["scan", "escape", "until-denied"])
    p.add_argument("--cfg", required=True)
    p.add_argument("--own")
    p.add_argument("--locations")
    p.add_argument("--out")
    a = p.parse_args()
    cfg = json.load(open(a.cfg))
    locs = json.load(open(a.locations)) if a.locations else []
    if a.mode == "scan":
        res = {"readable": scan(cfg, locs), "of": len(locs)}
    elif a.mode == "escape":
        res = run_escape(cfg, a.own, locs)
    else:
        res = until_denied(cfg, a.own)
    s = json.dumps(res, indent=2)
    if a.out:
        open(a.out, "w").write(s)
    print(s)
