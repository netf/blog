# Shared helpers. try_pod NAME IMAGE: creates a pod in ns prod, prints one TSV
# line: name, decision (ALLOWED/DENIED), wall ms for the create call, message.
export PATH="$HOME/bin:$PATH"
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
now_ms() { date +%s%3N; }
try_pod() {
  local name=$1 image=$2 t0 t1 out rc
  t0=$(now_ms)
  out=$(kubectl -n prod run "$name" --image="$image" --restart=Never \
        --env=APP_SECRET=lab-secret-value 2>&1); rc=$?
  t1=$(now_ms)
  local dec=ALLOWED; [ $rc -ne 0 ] && dec=DENIED
  printf '%s\t%s\t%s\t%s\n' "$name" "$dec" "$((t1-t0))" "$(echo "$out" | tr '\n' ' ' | cut -c1-400)"
  kubectl -n prod delete pod "$name" --wait=false >/dev/null 2>&1 || true
}
# apply_policy FILE [extra-key=value ...]: inline the cosign pubkey (indented to
# match each placeholder) and set extra fields on every verifyImages entry.
apply_policy() {
  local file=$1; shift
  python3 - "$file" "$LAB/keys/cosign.pub" "$@" <<'PY' | kubectl apply -f - >/dev/null
import sys, re
src, pub, extras = open(sys.argv[1]).read(), open(sys.argv[2]).read().strip(), sys.argv[3:]
def sub(m):
    ind = m.group(1)
    return ind + ("\n" + ind).join(pub.splitlines())
out = re.sub(r"^( *)__COSIGN_PUB__", sub, src, flags=re.M)
for kv in extras:
    k, v = kv.split("=", 1)
    out = out.replace("    - imageReferences:", f"    - {k}: {v}\n      imageReferences:", 1)
print(out)
PY
  kubectl wait --for=condition=Ready clusterpolicy --all --timeout=60s >/dev/null
}

# kyverno_mode default|ttl2m|off: set the verify-cache flags and restart cold.
kyverno_mode() {
  local MODE=$1 ARGS SARGS=
  case $MODE in
    default) ARGS='features.registryClient.allowInsecure=true' ;;
    ttl2m)   ARGS='features.registryClient.allowInsecure=true,admissionController.container.extraArgs.imageVerifyCacheTTLDuration=2m' ;;
    off)     ARGS='features.registryClient.allowInsecure=true'
             # the chart drops boolean false (`if $value`), so pass it as a string
             SARGS='admissionController.container.extraArgs.imageVerifyCacheEnabled=false' ;;
  esac
  helm upgrade kyverno kyverno/kyverno --version 3.9.1 -n kyverno \
    --set "$ARGS" ${SARGS:+--set-string "$SARGS"} --wait --timeout 5m >/dev/null
  kubectl -n kyverno rollout restart deploy/kyverno-admission-controller >/dev/null
  kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s >/dev/null
  sleep 10
}
