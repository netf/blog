#!/usr/bin/env bash
# Install-time cost and success across the 30-project corpus. No worm involved: this measures the
# controls, not the attack.
#   baseline  plain `npm ci` on the host, scripts on
#   hardened  bubblewrap + allowlist netns, --ignore-scripts, rebuild of allowlisted packages
#   landlock  Landlock + cleared env, --ignore-scripts, rebuild of allowlisted packages
# Warm: npm cache primed once, then WARM_N timed runs. Cold: npm cache wiped before each of
# COLD_N runs (the registry stays warm, as a CI registry proxy would be).
# COMPILE_CACHE=keep OVERHEAD_OUT=overhead-compile-cache.jsonl reruns it with a persistent Node
# compile cache per regime (see stage-install.sh).
# Modes are interleaved per project so drift on the VM hits all three equally.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
WARM_N="${WARM_N:-5}"; COLD_N="${COLD_N:-3}"; MODES=(${MODES:-baseline hardened landlock})
OUT="${RESULTS}/${OVERHEAD_OUT:-overhead.jsonl}"; : > "${OUT}"
sudo bash "${LAB_DIR}/scripts/netns-up.sh" allowlist >/dev/null 2>&1

one() { # dir mode state cachedir run emit(0/1)
  local D="$1" M="$2" S="$3" C="$4" R="$5" E="$6" SC=on ALLOW="" T="${RUN_DIR}/one.json"
  rm -rf "${D}/node_modules"; [ "${S}" = cold ] && rm -rf "${C}"; mkdir -p "${C}"
  [ "${M}" != baseline ] && { SC=off; ALLOW="$(tr '\n' ' ' < "${D}/allowlist.txt")"; }
  : > "${T}"
  bash "${LAB_DIR}/scripts/stage-install.sh" --mode "${M}" --project "${D}" --scripts "${SC}" \
    --cache "${C}" --allow "${ALLOW}" --out "${T}"
  [ "${E}" = 1 ] && node -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));o.cache_state=process.argv[2];o.compile_cache=process.env.COMPILE_CACHE||"default";o.run=+process.argv[3];console.log(JSON.stringify(o))' "${T}" "${S}" "${R}" >> "${OUT}"
  return 0
}

for D in "${LAB_DIR}"/corpus/projects/*/; do
  D="${D%/}"
  for M in "${MODES[@]}"; do rm -rf "${RUN_DIR}/cache-${M}"; one "${D}" "${M}" prime "${RUN_DIR}/cache-${M}" 0 0; done
  for i in $(seq 1 "${WARM_N}"); do for M in "${MODES[@]}"; do one "${D}" "${M}" warm "${RUN_DIR}/cache-${M}" "${i}" 1; done; done
  for i in $(seq 1 "${COLD_N}"); do for M in "${MODES[@]}"; do one "${D}" "${M}" cold "${RUN_DIR}/cache-${M}" "${i}" 1; done; done
  log "overhead $(basename "${D}") done"
done
log "overhead complete -> ${OUT}"
