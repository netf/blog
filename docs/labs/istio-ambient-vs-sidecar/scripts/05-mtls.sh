#!/usr/bin/env bash
# mTLS: (1) what is actually on the wire between nodes for each mode, and
# (2) whether STRICT PeerAuthentication rejects a non-mesh client.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$LAB_DIR/results/mtls"
mkdir -p "$OUT"
MARKER="X-Lab-Marker: PLAINTEXT-CANARY-42"

capture() { # mode
  local ns=$1 pcap="/tmp/${1}.pcap"
  # Capture on the server node's eth0: cross-node pod traffic leaves/enters here.
  docker run -d --rm --name "cap-$ns" --net container:mesh-lab-worker2 -v /tmp:/tmp \
    nicolaka/netshoot:v0.15 tcpdump -i eth0 -nn -s0 -U -w "$pcap" \
    'tcp and not port 6443 and not port 10250 and not port 15012 and not port 15010' >/dev/null
  sleep 2
  for _ in 1 2 3 4 5; do
    kubectl -n "$ns" exec deploy/client -c fortio -- fortio curl -H "$MARKER" http://server:8080/echo >/dev/null 2>&1
  done
  sleep 1
  docker stop "cap-$ns" >/dev/null
  {
    echo "== $ns"
    echo -n "packets containing marker: "
    docker run --rm -v /tmp:/tmp nicolaka/netshoot:v0.15 sh -c "tcpdump -nn -A -r $pcap 2>/dev/null | grep -c PLAINTEXT-CANARY-42 || true"
    echo "dst ports seen on the wire (SYNs, count port):"
    docker run --rm -v /tmp:/tmp nicolaka/netshoot:v0.15 sh -c \
      "tcpdump -nn -r $pcap 'tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0' 2>/dev/null | awk '{print \$5}' | sed 's/.*\\.//; s/://' | sort | uniq -c"
    echo "TLS ClientHello / SNI:"
    docker run --rm -v /tmp:/tmp nicolaka/netshoot:v0.15 sh -c \
      "tshark -r $pcap -Y tls.handshake.type==1 -T fields -e tcp.dstport -e tls.handshake.extensions_server_name -e tls.handshake.extensions_alpn_str 2>/dev/null | sort | uniq -c"
  } | tee -a "$OUT/wire.txt"
}

: > "$OUT/wire.txt"
for ns in baseline sidecar ambient ambient-wp; do capture "$ns"; done

# Identity as seen by the server side
kubectl -n sidecar exec deploy/client -c fortio -- fortio curl http://server:8080/debug 2>&1 \
  | grep -i x-forwarded-client-cert > "$OUT/identity-sidecar.txt" || true
kubectl -n istio-system logs "$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=mesh-lab-worker2 -o name)" --since=60s \
  | grep 'ns=ambient ' | grep -m3 -E 'src.identity|dst.identity' > "$OUT/identity-ambient-ztunnel.txt" || true

# STRICT mesh-wide, then call each meshed server from the non-mesh client
kubectl apply -f - <<'EOF'
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF
sleep 10
: > "$OUT/strict.txt"
for target in sidecar ambient ambient-wp; do
  echo "== baseline client -> server.$target (STRICT)" | tee -a "$OUT/strict.txt"
  kubectl -n baseline exec deploy/client -c fortio -- fortio curl -timeout 3s "http://server.$target:8080/echo" 2>&1 \
    | grep -E 'HTTP/1.1|error|Error|reset|refused|EOF' | head -3 | tee -a "$OUT/strict.txt" || true
done
kubectl -n istio-system delete peerauthentication default
sleep 10
echo "== baseline client -> server.ambient (PERMISSIVE, after delete)" | tee -a "$OUT/strict.txt"
kubectl -n baseline exec deploy/client -c fortio -- fortio curl -timeout 3s http://server.ambient:8080/echo 2>&1 \
  | grep -E 'HTTP/1.1|error' | head -2 | tee -a "$OUT/strict.txt" || true
