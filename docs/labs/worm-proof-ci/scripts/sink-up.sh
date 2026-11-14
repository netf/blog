#!/usr/bin/env bash
# (Re)start the canary sink on the host side of the veth with an empty log.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pkill -f sink-server.cjs 2>/dev/null || true; sleep 0.3
: > "${RUN_DIR}/sink.log"
HOST_IP="${HOST_IP}" HTTP_SINK_PORT="${HTTP_SINK_PORT}" DNS_SINK_PORT="${DNS_SINK_PORT}" SINK_LOG="${RUN_DIR}/sink.log" \
  setsid node "${LAB_DIR}/scripts/sink-server.cjs" </dev/null > "${RUN_DIR}/sink.out" 2>&1 &
for i in $(seq 1 30); do grep -q "dns on" "${RUN_DIR}/sink.out" 2>/dev/null && grep -q "http on" "${RUN_DIR}/sink.out" && break; sleep 0.1; done
