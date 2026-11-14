#!/usr/bin/env bash
# Shared helpers. Every script sources this.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HERE}/../config/lab.env"
export RESULTS="${LAB_DIR}/results"
export RUN_DIR="${LAB_DIR}/.run"       # scratch: pids, tokens, workspaces (gitignored)
mkdir -p "${RESULTS}" "${RUN_DIR}"
# When invoked via sudo, keep scratch owned by the real user so later unprivileged steps can write.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  chown "${SUDO_USER}:${SUDO_USER}" "${RESULTS}" "${RUN_DIR}" 2>/dev/null || true
fi
# Node install dir, derived from npm (node on PATH may be a shim without npm beside it).
export NODE_DIR="$(dirname "$(dirname "$(command -v npm)")")"
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
