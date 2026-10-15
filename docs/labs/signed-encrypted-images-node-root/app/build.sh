#!/usr/bin/env bash
# Builds the static binary and an 8 MiB "proprietary" file whose first line is a
# known marker, so later steps can grep for it in registry blobs and snapshots.
set -euo pipefail
export PATH="/usr/local/go/bin:$PATH"
cd "$(dirname "$0")"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o demoapp .
{ echo "PROPRIETARY-MODEL-MARKER-7f3a9c"; head -c 8388608 /dev/urandom; } > model.bin
