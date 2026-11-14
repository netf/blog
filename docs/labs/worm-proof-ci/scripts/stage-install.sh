#!/usr/bin/env bash
# Run one install under one regime and append a JSON result line to --out.
#
#   baseline  plain `npm ci` on the host: victim $HOME with canaries, canary env, a functional
#             registry credential in scope. A typical CI job.
#   sandbox   bubblewrap inside the allowlist netns: empty tmpfs $HOME, cleared env, only the
#             workspace + npm cache writable, egress only to the registry. Scripts still run
#             (with --scripts on), to isolate what the sandbox alone buys.
#   hardened  sandbox + `npm ci --ignore-scripts`, then `npm rebuild` for --allow packages only.
#   landlock  no root, no netns: cleared env, fresh $HOME, Landlock limits writes to the
#             workspace/cache/tmp, reads to system dirs + Node + workspace, and TCP connect to
#             the registry port. Honours --scripts and --allow like hardened.
#
# Flags: --mode M --project DIR --scripts on|off --cache DIR --allow "p1 p2" --out FILE
#        --behaviors "scan,exfil,publish,workspace,githook,escape,detach"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE=hardened PROJECT="" SCRIPTS=off CACHE="" ALLOW="" OUT=/dev/null BEHAVIORS=""
# COMPILE_CACHE=keep gives every regime a persistent Node compile cache inside its npm cache dir.
# Without it the sandboxes start with an empty one on every run (fresh /tmp), the baseline does not.
COMPILE_CACHE="${COMPILE_CACHE:-default}"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2";; --project) PROJECT="$2";; --scripts) SCRIPTS="$2";; --cache) CACHE="$2";;
    --allow) ALLOW="$2";; --out) OUT="$2";; --behaviors) BEHAVIORS="$2";;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac; shift 2
done
PROJECT="$(cd "${PROJECT}" && pwd)"
CACHE="${CACHE:-${RUN_DIR}/npm-cache-${MODE}}"; mkdir -p "${CACHE}"
REPORTS="${RUN_DIR}/reports"; mkdir -p "${REPORTS}"
WR="${REPORTS}/worm-${MODE}.jsonl"; : > "${WR}"
LL="${LAB_DIR}/landlock/landlock-run"
CC_ENV=(); [ "${COMPILE_CACHE}" = keep ] && CC_ENV=(NODE_COMPILE_CACHE="${CACHE}/node-compile-cache")
CC_BW=(); [ "${COMPILE_CACHE}" = keep ] && CC_BW=(--setenv NODE_COMPILE_CACHE "${CACHE}/node-compile-cache")
U="$(id -u)"; G="$(id -g)"

if [ -f "${PROJECT}/package-lock.json" ]; then NPMSUB=ci; else NPMSUB=install; fi
NPM_FLAGS=(--registry "${REGISTRY_URL}" --no-audit --no-fund --loglevel=error --cache "${CACHE}")
[ "${SCRIPTS}" = off ] && NPM_FLAGS+=(--ignore-scripts)

# bubblewrap inside the jail netns, dropped to the invoking user. Args after it: the command.
in_bwrap() {
  sudo ip netns exec "${NETNS}" setpriv --reuid "${U}" --regid "${G}" --clear-groups \
    bwrap --unshare-user --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup \
      --die-with-parent --new-session \
      --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /sbin /sbin \
      --ro-bind-try /lib /lib --ro-bind-try /lib64 /lib64 --ro-bind /etc /etc \
      --ro-bind "${NODE_DIR}" "${NODE_DIR}" \
      --proc /proc --dev /dev --tmpfs /tmp --tmpfs /sbx-home \
      --bind "${PROJECT}" "${PROJECT}" --bind "${CACHE}" "${CACHE}" --bind "${REPORTS}" "${REPORTS}" \
      --chdir "${PROJECT}" --clearenv \
      --setenv HOME /sbx-home --setenv PATH "${NODE_DIR}/bin:/usr/bin:/bin" \
      --setenv WORM_REPORT "${WR}" --setenv WORM_BEHAVIORS "${BEHAVIORS}" "${CC_BW[@]}" \
      "$@" </dev/null
}

# Landlock on the host, unprivileged. A fresh tmp dir is both $HOME and $TMPDIR.
in_landlock() {
  local T; T="$(mktemp -d /tmp/ll-XXXXXX)"; mkdir -p "${T}/home"
  ( cd "${PROJECT}" && env -i HOME="${T}/home" TMPDIR="${T}" PATH="${NODE_DIR}/bin:/usr/bin:/bin" \
      WORM_REPORT="${WR}" WORM_BEHAVIORS="${BEHAVIORS}" "${CC_ENV[@]}" \
      "${LL}" -r /usr -r /bin -r /sbin -r /lib -r /lib64 -r /etc -r /proc -r /sys -r /dev -r "${NODE_DIR}" \
        -w /dev/null -w "${PROJECT}" -w "${CACHE}" -w "${T}" -w "${REPORTS}" \
        -c "${REGISTRY_PORT}" -- "$@" </dev/null )
  local rc=$?; rm -rf "${T}"; return "${rc}"
}

run_install() {
  case "${MODE}" in
    baseline)
      ( cd "${PROJECT}" && env -i HOME="${RUN_DIR}/victim-home" PATH="${NODE_DIR}/bin:/usr/bin:/bin" \
          $(cat "${RUN_DIR}/victim.env") WORM_REPORT="${WR}" WORM_BEHAVIORS="${BEHAVIORS}" "${CC_ENV[@]}" \
          npm "${NPMSUB}" "${NPM_FLAGS[@]}" </dev/null ) ;;
    sandbox|hardened) in_bwrap npm "${NPMSUB}" "${NPM_FLAGS[@]}" ;;
    landlock) in_landlock npm "${NPMSUB}" "${NPM_FLAGS[@]}" ;;
    *) echo "bad mode ${MODE}" >&2; exit 2;;
  esac
}

T0=$(date +%s.%N)
set +e
run_install > "${RUN_DIR}/install-${MODE}.out" 2>&1
RC=$?
# Re-enable install scripts only for the explicitly allowlisted packages.
if [ "${RC}" = 0 ] && [ "${SCRIPTS}" = off ] && [ -n "${ALLOW// /}" ]; then
  case "${MODE}" in
    hardened) in_bwrap npm rebuild ${ALLOW} --registry "${REGISTRY_URL}" --loglevel=error ;;
    landlock) in_landlock npm rebuild ${ALLOW} --registry "${REGISTRY_URL}" --loglevel=error ;;
  esac >> "${RUN_DIR}/install-${MODE}.out" 2>&1
  RC=$?
fi
set -e
T1=$(date +%s.%N)
node -e 'const a=process.argv.slice(1);process.stdout.write(JSON.stringify({project:a[0],mode:a[1],scripts:a[2],install_seconds:+(+a[3]).toFixed(3),exit_code:+a[4],npm:a[5]})+"\n")' \
  "$(basename "${PROJECT}")" "${MODE}" "${SCRIPTS}" "$(echo "${T1} - ${T0}" | bc)" "${RC}" "${NPMSUB}" >> "${OUT}"
# (compile_cache is recorded by the overhead driver)
