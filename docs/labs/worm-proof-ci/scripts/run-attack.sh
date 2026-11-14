#!/usr/bin/env bash
# The worm against the victim project under each regime, N times. Recorded per run: secrets the
# worm's scan found, distinct canaries that reached the sink over HTTP and over DNS, new worm
# versions that appeared in the registry (self-publish), and writes into the checkout.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "${LAB_DIR}/scripts/common-attack.sh"
N="${N:-5}"; OUT="${RESULTS}/attack.jsonl"; : > "${OUT}"
sudo bash "${LAB_DIR}/scripts/netns-up.sh" allowlist >/dev/null 2>&1
for ARM in baseline sandbox landlock hardened; do
  for i in $(seq 1 "${N}"); do
    reset_victim
    B="$(versions99)"
    bash "${LAB_DIR}/scripts/stage-install.sh" --mode "${ARM}" --project "${VA}" --scripts "$(scripts_for "${ARM}")" \
      --behaviors scan,exfil,publish,workspace,githook --out "${RUN_DIR}/attack-one.json"
    sleep 1; A="$(versions99)"
    node -e 'const a=process.argv.slice(1);console.log(JSON.stringify({arm:a[0],run:+a[1],worm_ran:a[2]!=="",scan_count:+(a[2]||0),canaries_http:+a[3],canaries_dns:+a[4],self_publish_versions:a[6]-a[5],workspace_write:+a[7],git_hook_write:+a[8],publish_error:a[9]}))' \
      "${ARM}" "${i}" "$(worm_field "${ARM}" steps.scan.count)" "$(sink_canaries http)" "$(sink_canaries dns)" "${B}" "${A}" \
      "$([ -f "${VA}/WORM_WAS_HERE.txt" ] && echo 1 || echo 0)" "$([ -f "${VA}/.git/hooks/pre-commit" ] && echo 1 || echo 0)" \
      "$(worm_field "${ARM}" 'steps.publish&&(r.steps.publish.stderr.match(/code (\w+)/)||[])[1]')" | tee -a "${OUT}" >&2
  done
done
log "attack complete -> ${OUT}"
