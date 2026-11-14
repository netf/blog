#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -f "${RUN_DIR}/verdaccio.pid" ] && kill "$(cat "${RUN_DIR}/verdaccio.pid")" 2>/dev/null; pkill -x verdaccio 2>/dev/null || true
pkill -f sink-server.cjs 2>/dev/null || true
log "registry + sink stopped"
