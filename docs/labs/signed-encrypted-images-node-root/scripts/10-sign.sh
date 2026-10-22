#!/usr/bin/env bash
# Signs app:v1 by digest with a local cosign key (no Fulcio, no Rekor: the lab
# is offline-by-design), then attaches a CycloneDX SBOM from syft and a
# SLSA provenance predicate as signed attestations.
set -euo pipefail
export PATH="$HOME/bin:$PATH"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/results/sign"; mkdir -p "$OUT" "$HERE/keys"
IMG=kind-registry:5000/demo/app
DIGEST=$(skopeo inspect --tls-verify=false "docker://$IMG:v1" | jq -r .Digest)
REF="$IMG@$DIGEST"
echo "$REF" > "$OUT/signed-ref.txt"
cd "$HERE/keys"
[ -f cosign.key ] || COSIGN_PASSWORD= cosign generate-key-pair >/dev/null
CO=(--key cosign.key --allow-http-registry --allow-insecure-registry
    --use-signing-config=false --tlog-upload=false --yes)
COSIGN_PASSWORD= cosign sign "${CO[@]}" "$REF" > "$OUT/sign.log" 2>&1

syft scan --quiet "registry:$REF" -o cyclonedx-json > "$OUT/sbom.cdx.json" 2>"$OUT/syft.log" \
  || SYFT_REGISTRY_INSECURE_USE_HTTP=true syft scan --quiet "registry:$REF" -o cyclonedx-json > "$OUT/sbom.cdx.json"
COSIGN_PASSWORD= cosign attest "${CO[@]}" --type cyclonedx --predicate "$OUT/sbom.cdx.json" "$REF" > "$OUT/attest-sbom.log" 2>&1

cat > "$OUT/provenance.json" <<JSON
{"buildDefinition":{"buildType":"https://netf.io/lab/docker-build@v1",
  "externalParameters":{"source":"docs/labs/signed-encrypted-images-node-root/app"}},
 "runDetails":{"builder":{"id":"https://netf.io/lab/builder/laptop"},
  "metadata":{"invocationId":"lab-$(date -u +%Y%m%dT%H%M%SZ)"}}}
JSON
COSIGN_PASSWORD= cosign attest "${CO[@]}" --type slsaprovenance1 --predicate "$OUT/provenance.json" "$REF" > "$OUT/attest-prov.log" 2>&1
skopeo list-tags --tls-verify=false "docker://$IMG" > "$OUT/tags-after.json"
