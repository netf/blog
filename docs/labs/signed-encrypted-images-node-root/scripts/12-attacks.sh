#!/usr/bin/env bash
# Admission attacks against the verify-lab-images policy. One TSV line per try.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$LAB/results/admission"; mkdir -p "$OUT"
R=kind-registry:5000/demo/app
SK=(--all --preserve-digests --src-tls-verify=false --dest-tls-verify=false)
kyverno_mode default
apply_policy "$LAB/manifests/policy-verify.yaml" type=SigstoreBundle 2>/dev/null
GOOD=$(cut -d@ -f2 "$LAB/results/sign/signed-ref.txt")
EVIL=$(skopeo inspect --tls-verify=false "docker://$R:evil" | jq -r .Digest)
tag_of() { echo "sha256-${1#sha256:}"; }
{
try_pod control-signed-tag    "$R:v1"
try_pod control-signed-digest "$R@$GOOD"
try_pod unsigned-tag          "$R:evil"
try_pod unsigned-digest       "$R@$EVIL"

# Transplant: an attacker with registry write access copies v1's valid
# signature index (raw manifest GET + PUT) onto an unsigned image's referrer tag.
EVIL2=$(skopeo inspect --tls-verify=false "docker://$R:evil2" | jq -r .Digest)
AC='Accept: application/vnd.oci.image.index.v1+json'
curl -sf -H "$AC" "http://kind-registry:5000/v2/demo/app/manifests/$(tag_of "$GOOD")" -o /tmp/sig-index.json
curl -sf -X PUT -H 'Content-Type: application/vnd.oci.image.index.v1+json' --data-binary @/tmp/sig-index.json \
  "http://kind-registry:5000/v2/demo/app/manifests/$(tag_of "$EVIL2")" -o /dev/null -w '#\ttransplant PUT\t%{http_code}\n'
try_pod transplanted-signature "$R@$EVIL2"

# Tag repoint: overwrite :v1 so it now points at the evil digest.
skopeo copy -q "${SK[@]}" "docker://$R@$EVIL" "docker://$R:v1"
echo -e "#\tv1 now resolves to\t$(skopeo inspect --tls-verify=false docker://$R:v1 | jq -r .Digest)"
try_pod repointed-tag          "$R:v1"
try_pod repoint-pinned-digest  "$R@$GOOD"
skopeo copy -q "${SK[@]}" "docker://$R@$GOOD" "docker://$R:v1"
try_pod restored-tag           "$R:v1"
} | tee "$OUT/attacks.tsv"
