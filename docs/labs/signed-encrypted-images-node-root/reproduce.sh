#!/usr/bin/env bash
# One command: ./reproduce.sh  (about 25 minutes; add DEFAULT_TTL=1 for the
# extra 11-minute observation of the stale window at Kyverno's default TTL).
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/bin:/usr/local/go/bin:$PATH"
s() { echo; echo "### $*"; bash "scripts/$@"; }
s 00-tools.sh; s 00b-start-dockerd.sh; s 01-preflight.sh
s 03-cluster.sh; s 09-images.sh; s 10-sign.sh; s 11-kyverno.sh
s 11b-format-compat.sh; s 12-attacks.sh
s 13-repoint-cache.sh ttl2m
LIMIT=25 STEP=10 s 13-repoint-cache.sh off
[ "${DEFAULT_TTL:-0}" = 1 ] && LIMIT=660 STEP=120 s 13-repoint-cache.sh default
s 14-registry-down.sh; s 14b-failure-modes.sh; s 14c-kyverno-crash.sh; s 14d-two-replicas.sh; s 15-latency.sh
s 20-encrypt.sh; s 21-stolen-copy.sh; s 22-node-keys.sh; s 23-run-encrypted.sh
s 30-node-root.sh
echo "done: results/ refreshed"
