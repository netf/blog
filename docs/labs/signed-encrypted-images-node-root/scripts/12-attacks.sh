#!/usr/bin/env bash
# Admission attacks against the verify-lab-images policy. One TSV line per try.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$LAB/results/admission"; mkdir -p "$OUT"
R=kind-registry:5000/demo/app
SK=(--src-tls-verify=false --dest-tls-verify=false)
apply_policy "$LAB/manifests/policy-verify.yaml" type=SigstoreBundle 2>/dev/null
GOOD=$(cut -d@ -f2 "$LAB/results/sign/signed-ref.txt")
EVIL=$(skopeo inspect --tls-verify=false "docker://$R:evil" | jq -r .Digest)
tag_of() { echo "sha256-${1#sha256:}"; }
{
try_pod control-signed-tag    "$R:v1"
try_pod control-signed-digest "$R@$GOOD"
try_pod unsigned-tag          "$R:evil"
try_pod unsigned-digest       "$R@$EVIL"

# Transplant: copy v1's valid signature/attestation index onto the evil digest's
# referrer tag, as an attacker with registry write access could.
skopeo copy -q --all "${SK[@]}" "docker://$R:$(tag_of "$GOOD")" "docker://$R:$(tag_of "$EVIL")"
try_pod transplanted-signature "$R@$EVIL"
skopeo delete --tls-verify=false "docker://$R:$(tag_of "$EVIL")" 2>/dev/null || true

# Tag repoint: overwrite :v1 so it now points at the evil digest.
skopeo copy -q "${SK[@]}" "docker://$R@$EVIL" "docker://$R:v1"
echo -e "#\tv1 now resolves to\t$(skopeo inspect --tls-verify=false docker://$R:v1 | jq -r .Digest)"
try_pod repointed-tag          "$R:v1"
try_pod repoint-pinned-digest  "$R@$GOOD"
skopeo copy -q "${SK[@]}" "docker://$R@$GOOD" "docker://$R:v1"
try_pod restored-tag           "$R:v1"
} | tee "$OUT/attacks.tsv"
