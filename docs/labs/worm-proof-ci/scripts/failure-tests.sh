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

log "4. writes into the checkout, and attempts to write outside it"
for M in "${RUNNING[@]}"; do
  reset_victim
  bash "${LAB_DIR}/scripts/stage-install.sh" --mode "${M}" --project "${VA}" --scripts on --behaviors workspace,githook,escape
  emit test workspace_writes mode "${M}" workspace_file "$([ -f "${VA}/WORM_WAS_HERE.txt" ] && echo yes || echo no)" \
    git_hook "$([ -f "${VA}/.git/hooks/pre-commit" ] && echo yes || echo no)" \
    wrote_outside_workspace_on_host "$([ -f "${RUN_DIR}/workspaces/WORM_ESCAPE.txt" ] && echo yes || echo no)"
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
log "failure tests complete -> ${OUT}"
