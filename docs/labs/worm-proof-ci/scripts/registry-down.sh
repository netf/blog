#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ -f "${RUN_DIR}/verdaccio.pid" ]; then kill "$(cat "${RUN_DIR}/verdaccio.pid")" 2>/dev/null || true; fi; pkill -x verdaccio 2>/dev/null || true
pkill -f sink-server.cjs 2>/dev/null || true
log "registry + sink stopped"
