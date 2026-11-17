"""Lab-only helper: an identity-reporting server and a victim client.

server: answers HTTPS (TLS_PORT) and plain HTTP (HTTP_PORT) with {"responder": NAME, ...}
        and logs one JSON line per request with the plaintext bytes it received and
        whether the victim's canary was in them. TLS handshakes that fail are logged
        with the SNI the client sent.
client: sends N POSTs carrying a canary card number to --connect IP, with or without
        certificate verification, and prints a JSON summary of who answered.
"""
import argparse
import http.client
import json
import os
import socket
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CANARY = "CARD=4111111111111111;CVV=737;OWNER=tenant-a"


def log(**kw):
    kw["ts"] = time.time()
    print(json.dumps(kw), flush=True)


def make_handler(name, port_kind):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _serve(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n) if n else b""
            head = self.requestline.encode() + b"\r\n" + bytes(self.headers)
            got = len(head) + len(body)
            canary = CANARY.encode() in body or CANARY.encode() in head
            peer = self.client_address[0]
            log(event="req", responder=name, port=port_kind, path=self.path, peer=peer,
                host=self.headers.get("Host"), bytes=got, canary=canary)
            out = json.dumps({"responder": name, "path": self.path, "peer": peer,
                              "received_bytes": got}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        do_GET = do_POST = _serve

        def log_message(self, *a):
            pass

    return H


class TLSServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, addr, handler, ctx):
        super().__init__(addr, handler)
        self.ctx = ctx

    def finish_request(self, request, client_address):
        sni = {}
        self.ctx.sni_callback = lambda s, name, c: sni.__setitem__("sni", name)
        try:
            tls = self.ctx.wrap_socket(request, server_side=True)
        except (ssl.SSLError, OSError) as e:
            log(event="tls_fail", responder=self.name, peer=client_address[0],
                sni=sni.get("sni"), error=str(e)[:120])
            return
        self.RequestHandlerClass(tls, client_address, self)


def serve(a):
    name = a.name
    servers = []
    ThreadingHTTPServer.address_family = socket.AF_INET6
    httpd = ThreadingHTTPServer(("::", a.http_port), make_handler(name, "http"))
    servers.append(httpd)
    if a.cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(a.cert, a.key)
        TLSServer.address_family = socket.AF_INET6
        tlsd = TLSServer(("::", a.tls_port), make_handler(name, "https"), ctx)
        tlsd.name = name
        servers.append(tlsd)
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    log(event="listening", responder=name, http=a.http_port, https=a.tls_port if a.cert else None)
    while True:
        time.sleep(3600)


def client(a):
    responders, errors = {}, {}
    sent = 0
    body = (CANARY + ";" + "x" * 1024)[:1024].encode()
    for _ in range(a.n):
        try:
            if a.scheme == "https":
                ctx = ssl.create_default_context(cafile=a.ca) if a.verify else ssl._create_unverified_context()
                conn = http.client.HTTPSConnection(a.connect, a.port, timeout=a.timeout, context=ctx)
                # SNI and certificate name are the service's DNS name, not the IP.
                raw = socket.create_connection((a.connect, a.port), timeout=a.timeout)
                conn.sock = ctx.wrap_socket(raw, server_hostname=a.host)
            else:
                conn = http.client.HTTPConnection(a.connect, a.port, timeout=a.timeout)
            conn.request("POST", a.path, body=body, headers={"Host": a.host, "Content-Type": "text/plain"})
            r = conn.getresponse()
            data = r.read()
            sent += len(body)
            try:
                who = json.loads(data)["responder"]
            except Exception:
                who = f"http-{r.status}"
            responders[who] = responders.get(who, 0) + 1
            conn.close()
        except Exception as e:
            k = type(e).__name__ + ":" + str(e)[:80]
            errors[k] = errors.get(k, 0) + 1
        time.sleep(a.sleep)
    print(json.dumps({"target": f"{a.scheme}://{a.host}:{a.port}{a.path}", "connect": a.connect,
                      "verify": a.verify, "n": a.n, "responders": responders, "errors": errors,
                      "canary_bytes_sent": sent}))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--name", default=os.environ.get("NAME", "unknown"))
    s.add_argument("--http-port", type=int, default=8080)
    s.add_argument("--tls-port", type=int, default=8443)
    s.add_argument("--cert")
    s.add_argument("--key")
    c = sub.add_parser("client")
    c.add_argument("--connect", required=True)
    c.add_argument("--host", required=True)
    c.add_argument("--port", type=int, default=443)
    c.add_argument("--scheme", default="https")
    c.add_argument("--path", default="/charge")
    c.add_argument("--verify", action="store_true")
    c.add_argument("--ca", default="/certs/ca.crt")
    c.add_argument("--n", type=int, default=20)
    c.add_argument("--sleep", type=float, default=0.05)
    c.add_argument("--timeout", type=float, default=3)
    a = p.parse_args()
    serve(a) if a.cmd == "serve" else client(a)


if __name__ == "__main__":
    sys.exit(main())
