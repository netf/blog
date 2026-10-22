#!/usr/bin/env bash
# Attacker has read access to the registry (or a stolen copy of its storage)
# but no private key. Can they read the proprietary model? What leaks anyway?
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$LAB/results/stolen-copy"; mkdir -p "$OUT"; W=$(mktemp -d)
REG=http://kind-registry:5000/v2/demo
AM='Accept: application/vnd.oci.image.manifest.v1+json'
for img in app-plain app-enc; do
  t0=$(now_ms)
  curl -sf -H "$AM" "$REG/$img/manifests/v1" > "$W/$img.manifest.json"
  cfg=$(jq -r .config.digest "$W/$img.manifest.json")
  curl -sf "$REG/$img/blobs/$cfg" > "$W/$img.config.json"
  for l in $(jq -r '.layers[].digest' "$W/$img.manifest.json"); do
    curl -sf "$REG/$img/blobs/$l" > "$W/$img.$(echo "$l" | cut -c8-19).blob"
  done
  hits=$(cat "$W/$img".*.blob | (gzip -dc 2>/dev/null || true) | grep -a -c PROPRIETARY-MODEL-MARKER)
  raw=$(cat "$W/$img".*.blob | grep -a -c PROPRIETARY-MODEL-MARKER)
  printf '%s\tmarker-after-gunzip=%s\tmarker-raw=%s\tms=%s\n' "$img" "$hits" "$raw" "$(( $(now_ms)-t0 ))"
done | tee "$OUT/marker.tsv"

{
echo "== tar listing of each encrypted blob (no key)"
for b in "$W"/app-enc.*.blob; do echo "-- $(basename "$b")"; tar tzf "$b" 2>&1 | head -2; done
echo "== tar listing of plain blobs"
for b in "$W"/app-plain.*.blob; do echo "-- $(basename "$b")"; tar tzf "$b" 2>&1 | head -3; done
echo "== encrypted image config is plaintext JSON:"
jq -c '{Entrypoint: .config.Entrypoint, User: .config.User, Env: .config.Env,
        history: [.history[]?.created_by], diff_ids: .rootfs.diff_ids}' "$W/app-enc.config.json"
echo "== ocicrypt layer annotations (keys wrapped per recipient):"
jq -r '.layers[0].annotations | to_entries[] | "\(.key) (\(.value | length) chars)"' "$W/app-enc.manifest.json"
echo "== pubopts (base64 JSON):"
jq -r '.layers[0].annotations["org.opencontainers.image.enc.pubopts"]' "$W/app-enc.manifest.json" | base64 -d; echo
} | tee "$OUT/leaks.txt"

# The config blob is shared and plaintext: its diff_ids are sha256 of the
# *decrypted* layer tars, so a guessed plaintext layer can be confirmed.
{
for img in app-plain app-enc; do
  echo "$img config=$(jq -r .config.digest "$W/$img.manifest.json") diff_ids=$(jq -c .rootfs.diff_ids "$W/$img.config.json")"
done
for b in "$W"/app-plain.*.blob; do echo "sha256(gunzip($(basename "$b")))=sha256:$(gzip -dc "$b" | sha256sum | cut -d' ' -f1)"; done
} | tee "$OUT/diff-ids.txt"
rm -rf "$W"
