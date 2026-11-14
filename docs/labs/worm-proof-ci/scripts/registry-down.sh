#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pkill -f "verdaccio --config" 2>/dev/null || true
pkill -f sink-server.cjs 2>/dev/null || true
log "registry + sink stopped"
