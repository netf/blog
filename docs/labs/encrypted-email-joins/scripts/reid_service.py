"""Re-identification service: the only process that can turn a token back into an email or phone.

    reid_service.py [port]        (default 8787)

POST /reidentify {"column": "email", "tokens": ["<base64>", ...]}  -> {"values": [...]}
POST /tokenize   {"column": "email", "values": ["a@b.c", ...]}     -> {"tokens": [...]}

Callers authenticate with a bearer token from data/keys/callers.json. Each role lists the columns
it may reidentify and tokenize, a per-request cap and a per-minute budget of values. Tokenize is
permissioned separately because anyone who can tokenize can test guesses against the warehouse.
The audit log records who asked for what and how many, never the values.
"""
import base64
import json
import os
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import keys

ROLES = {
    "analyst": {"reidentify": [], "tokenize": [], "per_request": 0, "per_minute": 0},
    "support": {"reidentify": ["email"], "tokenize": ["email"], "per_request": 20, "per_minute": 60},
    "fraud": {"reidentify": ["email", "phone"], "tokenize": ["email", "phone"], "per_request": 100, "per_minute": 60_000},
    "pipeline": {"reidentify": [], "tokenize": ["email", "phone"], "per_request": 10_000, "per_minute": 10_000_000},
}
CALLERS = keys.KEY_DIR / "callers.json"
AUDIT = keys.KEY_DIR.parent / "reid-audit.jsonl"


def callers():
    if not CALLERS.exists():
        people = {"ana": "analyst", "sam": "support", "fio": "fraud", "etl": "pipeline"}
        CALLERS.write_text(json.dumps({secrets.token_urlsafe(24): {"id": i, "role": r} for i, r in people.items()}, indent=1))
    return json.loads(CALLERS.read_text())


class Budget:
    def __init__(self):
        self.lock = threading.Lock()
        self.spent = {}

    def take(self, who, n, per_minute):
        now = time.monotonic()
        with self.lock:
            window = [(t, k) for t, k in self.spent.get(who, []) if now - t < 60]
            if sum(k for _, k in window) + n > per_minute:
                self.spent[who] = window
                return False
            window.append((now, n))
            self.spent[who] = window
            return True


PRIMS = {c: keys.primitive(c) for c in ("email", "phone")}
WHO = callers()
BUDGET = Budget()
AUDIT_LOCK = threading.Lock()


def audit(**rec):
    rec["ts"] = round(time.time(), 3)
    with AUDIT_LOCK, open(AUDIT, "a") as f:
        f.write(json.dumps(rec) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        action = self.path.strip("/")
        length = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        auth = self.headers.get("authorization", "")
        caller = WHO.get(auth.removeprefix("Bearer ").strip())
        column = body.get("column")
        items = body.get("tokens" if action == "reidentify" else "values") or []
        base = {"action": action, "column": column, "count": len(items)}
        if caller is None:
            audit(caller=None, status=401, **base)
            return self.reply(401, {"error": "unknown caller"})
        role = ROLES[caller["role"]]
        base.update(caller=caller["id"], role=caller["role"])
        if action not in ("reidentify", "tokenize") or column not in role[action]:
            audit(status=403, **base)
            return self.reply(403, {"error": f"role {caller['role']} may not {action} {column}"})
        if len(items) > role["per_request"]:
            audit(status=413, **base)
            return self.reply(413, {"error": f"at most {role['per_request']} per request"})
        if not BUDGET.take(caller["id"], len(items), role["per_minute"]):
            audit(status=429, **base)
            return self.reply(429, {"error": f"budget is {role['per_minute']} per minute"})
        p, ad = PRIMS[column], column.encode()
        try:
            if action == "reidentify":
                out = {"values": [p.decrypt_deterministically(base64.b64decode(t), ad).decode() for t in items]}
            else:
                out = {"tokens": [base64.b64encode(p.encrypt_deterministically(v.encode(), ad)).decode() for v in items]}
        except Exception:
            audit(status=400, **base)
            return self.reply(400, {"error": "token does not decrypt under this column's keyset"})
        audit(status=200, **base)
        self.reply(200, out)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"reid service on 127.0.0.1:{port}, pid {os.getpid()}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
