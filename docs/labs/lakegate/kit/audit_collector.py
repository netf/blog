"""Receives MinIO audit webhook POSTs and appends one JSON object per line."""
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

out_dir = sys.argv[1]
os.makedirs(out_dir, exist_ok=True)
lock = threading.Lock()
fh = open(os.path.join(out_dir, "audit.jsonl"), "a", buffering=1)


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            entry = json.loads(body)
            line = json.dumps(entry, separators=(",", ":"))
        except ValueError:
            line = json.dumps({"raw": body.decode(errors="replace")})
        with lock:
            fh.write(line + "\n")
        self.send_response(200)
        self.end_headers()

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()
