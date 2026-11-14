#!/usr/bin/env bash
# The pitch's failure tests, each against the regimes where the worm's code actually runs
# (baseline, sandbox, landlock), plus the native-binary and publish-stage checks.
# Results: results/failure-tests.jsonl. Every outcome is observed from the host.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "${LAB_DIR}/scripts/common-attack.sh"
OUT="${RESULTS}/failure-tests.jsonl"; : > "${OUT}"
emit() { node -e 'const a=process.argv.slice(1),o={};for(let i=0;i<a.length;i+=2)o[a[i]]=isNaN(a[i+1])||a[i+1]===""?a[i+1]:+a[i+1];console.log(JSON.stringify(o))' "$@" | tee -a "${OUT}" >&2; }
sudo bash "${LAB_DIR}/scripts/netns-up.sh" allowlist >/dev/null 2>&1
RUNNING=(baseline sandbox landlock)

log "1. detached background process (does it outlive the install and keep exfiltrating?)"
for M in "${RUNNING[@]}"; do
  reset_victim
  bash "${LAB_DIR}/scripts/stage-install.sh" --mode "${M}" --project "${VA}" --scripts on --behaviors detach
  : > "${RUN_DIR}/sink.log"            # count only what arrives after the install returned
  sleep 1; ALIVE="$(pgrep -fc worm-bg- || true)"
  sleep 7; HITS="$(grep -c '"url":"/bg"' "${RUN_DIR}/sink.log" || true)"
  pkill -f worm-bg- 2>/dev/null || true
  emit test detached_bg_process mode "${M}" bg_processes_alive_after_exit "${ALIVE}" bg_sink_hits_after_exit "${HITS}"
done

log "2. exfiltration over HTTP and DNS, with a canary committed in the repo's .env"
for M in "${RUNNING[@]}"; do
  reset_victim repo-secret
  bash "${LAB_DIR}/scripts/stage-install.sh" --mode "${M}" --project "${VA}" --scripts on --behaviors scan,exfil
  sleep 1
  emit test exfiltration mode "${M}" secrets_found "$(worm_field "${M}" steps.scan.count)" \
    http_canaries "$(sink_canaries http)" dns_canaries "$(sink_canaries dns)" \
    repo_secret_found "$(grep -c "${CANARY_REPO}" "${RUN_DIR}/reports/worm-${M}.jsonl" || true)" \
    repo_secret_out_http "$(grep '"kind":"http"' "${RUN_DIR}/sink.log" | grep -c "${CANARY_REPO}" || true)" \
    repo_secret_out_dns "$(grep '"kind":"dns"' "${RUN_DIR}/sink.log" | grep -c "${CANARY_REPO}" || true)"
done

log "3. native-binary packages, functionally exercised, with and without the allowlist"
smoke() { # project code
  local D="${LAB_DIR}/corpus/projects/$1" R=()
  for W in noallow allow; do
    local A=""; [ "${W}" = allow ] && A="$(tr '\n' ' ' < "${D}/allowlist.txt")"
    rm -rf "${D}/node_modules"
    bash "${LAB_DIR}/scripts/stage-install.sh" --mode hardened --project "${D}" --scripts off --cache "${RUN_DIR}/cache-hardened" --allow "${A}"
    if ( cd "${D}" && env -i PATH="${NODE_DIR}/bin:/usr/bin:/bin" HOME=/tmp node --input-type=commonjs -e "$2" ) >/dev/null 2>&1; then R+=(pass); else R+=(fail); fi
  done
  emit test native_binary project "$1" declares_install_script "$([ -s "${D}/allowlist.txt" ] && echo yes || echo no)" without_allowlist "${R[0]}" with_allowlist "${R[1]}"
}
smoke esbuild        "process.exit(require('esbuild').transformSync('let x=1+1').code?0:1)"
smoke bcrypt         "const b=require('bcrypt');process.exit(b.compareSync('pw',b.hashSync('pw',4))?0:1)"
smoke swc-core       "process.exit(require('@swc/core').transformSync('let x=1+1').code?0:1)"
smoke sharp          "require('sharp')({create:{width:2,height:2,channels:3,background:'#123'}}).png().toBuffer().then(b=>process.exit(b.length?0:1),()=>process.exit(1))"
smoke better-sqlite3 "const db=new (require('better-sqlite3'))(':memory:');db.exec('create table t(x)');db.prepare('insert into t values (1)').run();process.exit(db.prepare('select count(*) c from t').get().c===1?0:1)"
smoke core-js        "require('core-js/actual/array/group-by');process.exit(typeof [].includes==='function'&&typeof Object.groupBy==='function'?0:1)"
# @parcel/watcher arrives with jest; exercise the native watcher, not just the require.
smoke jest           "const w=require('@parcel/watcher'),fs=require('fs'),d=fs.mkdtempSync('/tmp/pw-');w.subscribe(d,(e,ev)=>{if(ev.length)process.exit(0)}).then(()=>setTimeout(()=>fs.writeFileSync(d+'/x','1'),200));setTimeout(()=>process.exit(1),5000)"

log "4. writes into the checkout (file, git hook, git config), attempts to write outside it, and what a later git step runs"
GITOFF=(GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false)
later_stage() { # 'plain' | 'overrides' : run git status + git commit in the checkout the way a later CI step would
  rm -f "${VA}/HOOK_RAN" "${VA}/FSMONITOR_RAN"
  local E=(); [ "$1" = overrides ] && E=("${GITOFF[@]}")
  ( cd "${VA}" && env "${E[@]}" git status --porcelain >/dev/null 2>&1; env "${E[@]}" git -c user.email=ci@lab -c user.name=ci commit -q --allow-empty -m later >/dev/null 2>&1 ) || true
  echo "$([ -f "${VA}/HOOK_RAN" ] && echo yes || echo no) $([ -f "${VA}/FSMONITOR_RAN" ] && echo yes || echo no)"
}
for M in "${RUNNING[@]}"; do
  reset_victim
  bash "${LAB_DIR}/scripts/stage-install.sh" --mode "${M}" --project "${VA}" --scripts on --behaviors workspace,githook,gitconfig,escape
  WS="$([ -f "${VA}/WORM_WAS_HERE.txt" ] && echo yes || echo no)"; GH="$([ -f "${VA}/.git/hooks/pre-commit" ] && echo yes || echo no)"
  GC="$(grep -q FSMONITOR_RAN "${VA}/.git/config" && echo yes || echo no)"
  OUTSIDE="$([ -f "${RUN_DIR}/workspaces/WORM_ESCAPE.txt" ] && echo yes || echo no)"
  read -r HP FP <<<"$(later_stage plain)"; read -r HO FO <<<"$(later_stage overrides)"
  emit test workspace_writes mode "${M}" workspace_file "${WS}" git_hook_written "${GH}" git_config_written "${GC}" \
    wrote_outside_workspace_on_host "${OUTSIDE}" later_git_hook_ran "${HP}" later_fsmonitor_ran "${FP}" \
    with_overrides_hook_ran "${HO}" with_overrides_fsmonitor_ran "${FO}"
done

log "5. the publish stage: the install stage cannot publish, the publish stage can"
reset_victim
bash "${LAB_DIR}/scripts/stage-install.sh" --mode sandbox --project "${VA}" --scripts on --behaviors publish
INSTALL_ERR="$(worm_field sandbox 'steps.publish&&(r.steps.publish.stderr.match(/code (\w+)/)||[])[1]')"
P="${RUN_DIR}/workspaces/release-demo"; rm -rf "${P}"; mkdir -p "${P}"; echo 'module.exports=1' > "${P}/index.js"
node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({name:"@wormlab/release-demo",version:"1.0."+Date.now(),files:["index.js"],scripts:{prepublishOnly:"touch PREPUBLISH_RAN"}}))' "${P}/package.json"
if bash "${LAB_DIR}/scripts/stage-publish.sh" --project "${P}" >/dev/null 2>&1; then PUB=ok; else PUB=fail; fi
emit test publish_stage install_stage_worm_publish "${INSTALL_ERR}" publish_stage_publish "${PUB}" \
  publish_stage_ran_lifecycle_script "$([ -f "${P}/PREPUBLISH_RAN" ] && echo yes || echo no)"
log "6. a node-gyp package (better-sqlite3) when its install script is allowed to run in the jail"
# npm ci runs an implicit `node-gyp rebuild` for it (binding.gyp present; the lockfile has no
# hasInstallScript flag). The build is a no-op when a prebuild exists, but node-gyp first fetches
# Node headers from nodejs.org, which the registry-only egress policy blocks.
D6="${LAB_DIR}/corpus/projects/better-sqlite3"
for CASE in "sandbox:on::0" "hardened:off:better-sqlite3:0" "hardened:off:better-sqlite3:1" "landlock:off:better-sqlite3:0" "landlock:off:better-sqlite3:1"; do
  IFS=: read -r M SC A H <<<"${CASE}"
  rm -rf "${D6}/node_modules"; : > "${RUN_DIR}/t6.json"
  GYP_LOCAL_HEADERS="${H}" bash "${LAB_DIR}/scripts/stage-install.sh" --mode "${M}" --project "${D6}" --scripts "${SC}" \
    --allow "${A}" --cache "${RUN_DIR}/cache-${M}" --out "${RUN_DIR}/t6.json"
  RC="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).exit_code)' "${RUN_DIR}/t6.json")"
  WHY=-; grep -q 'headers.tar.gz failed' "${RUN_DIR}/install-${M}.out" && WHY="node-gyp could not fetch Node headers from nodejs.org"
  DNSWHY="$(grep -oE 'getaddrinfo [A-Z_]+' "${RUN_DIR}/install-${M}.out" | head -1 || true)"; [ -n "${DNSWHY}" ] && WHY="${WHY} (${DNSWHY})"
  emit test node_gyp_in_jail mode "${M}" scripts "${SC}" allow "${A:--}" local_node_headers "$([ "${H}" = 1 ] && echo yes || echo no)" install_exit "${RC}" failure "${WHY:--}"
done
log "failure tests complete -> ${OUT}"
