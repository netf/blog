"""Exercise the re-identification service. Starts it, runs the checks, stops it.

    test_reid.py RUNS > results/reid/reid.json
"""
import base64
import http.client
import json
import pathlib
import subprocess
import sys
import time

import pyarrow.parquet as pq

import keys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WH = ROOT / "data" / "warehouse"
PORT = 8787


def call(token, action, body):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("POST", f"/{action}", json.dumps(body), {"authorization": f"Bearer {token}", "content-type": "application/json"})
    r = c.getresponse()
    data = json.loads(r.read())
    c.close()
    return r.status, data


def main():
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    audit = keys.KEY_DIR.parent / "reid-audit.jsonl"
    audit.unlink(missing_ok=True)
    srv = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).with_name("reid_service.py")), str(PORT)],
                           stdout=subprocess.PIPE, text=True)
    srv.stdout.readline()
    who = {v["id"]: k for k, v in json.loads((keys.KEY_DIR / "callers.json").read_text()).items()}
    try:
        plain = pq.ParquetFile(WH / "plain" / "customers.parquet").read_row_group(0, columns=["email", "phone"]).slice(0, 200)
        enc = pq.ParquetFile(WH / "daead" / "customers.parquet").read_row_group(0, columns=["email", "phone"]).slice(0, 200)
        b64 = {c: [base64.b64encode(v).decode() for v in enc.column(c).to_pylist()] for c in ("email", "phone")}
        out = {"matrix": {}}

        for person in ("ana", "sam", "fio", "etl"):
            for action in ("reidentify", "tokenize"):
                for col in ("email", "phone"):
                    body = {"column": col, "tokens": b64[col][:1]} if action == "reidentify" else {"column": col, "values": [plain.column(col)[0].as_py()]}
                    out["matrix"][f"{person}/{action}/{col}"] = call(who[person], action, body)[0]

        st, data = call(who["fio"], "reidentify", {"column": "email", "tokens": b64["email"][:100]})
        out["round_trip_100"] = {"status": st, "all_match_plaintext": data["values"] == plain.column("email").to_pylist()[:100]}
        st, data = call(who["etl"], "tokenize", {"column": "email", "values": plain.column("email").to_pylist()[:100]})
        out["tokenize_matches_warehouse_100"] = data["tokens"] == b64["email"][:100]
        out["phone_token_sent_as_email"] = call(who["fio"], "reidentify", {"column": "email", "tokens": b64["phone"][:1]})[0]
        out["unknown_caller"] = call("not-a-token", "reidentify", {"column": "email", "tokens": b64["email"][:1]})[0]
        out["support_over_per_request_cap"] = call(who["sam"], "reidentify", {"column": "email", "tokens": b64["email"][:21]})[0]
        budget = [call(who["sam"], "reidentify", {"column": "email", "tokens": b64["email"][i * 20:(i + 1) * 20]})[0] for i in range(4)]
        out["support_budget_20x4_within_a_minute"] = budget

        lat = []
        for r in range(runs):
            ms = []
            for i in range(1000):
                t = time.perf_counter()
                st, _ = call(who["fio"], "reidentify", {"column": "email", "tokens": [b64["email"][i % 200]]})
                ms.append((time.perf_counter() - t) * 1000)
                assert st == 200
            ms.sort()
            lat.append({"run": r, "p50_ms": round(ms[499], 3), "p99_ms": round(ms[989], 3), "max_ms": round(ms[-1], 3)})
        out["single_token_latency"] = lat
    finally:
        srv.terminate()
        srv.wait()

    lines = audit.read_text().splitlines()
    text = audit.read_text()
    leaked = sum(1 for e in plain.column("email").to_pylist() if e in text)
    out["audit"] = {"records": len(lines), "plaintext_emails_found_in_log": leaked, "sample": [json.loads(l) for l in lines[:2]] +
                    [json.loads(l) for l in lines if '"status": 429' in l][:1]}
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
