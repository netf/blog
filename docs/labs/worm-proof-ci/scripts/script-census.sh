#!/usr/bin/env bash
# Ground truth for the allowlist: which lifecycle scripts does npm ACTUALLY run when each corpus
# project is installed normally? Compared against the lockfile's hasInstallScript flags.
# Runs on the host with scripts on (like baseline) and --foreground-scripts so npm prints every
# "> pkg@version <event>" banner. Results: results/script-census.jsonl
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OUT="${RESULTS}/script-census.jsonl"; : > "${OUT}"
for D in "${LAB_DIR}"/corpus/projects/*/; do
  D="${D%/}"; rm -rf "${D}/node_modules"
  LOGF="${RUN_DIR}/census-$(basename "${D}").log"
  ( cd "${D}" && env -i HOME="${RUN_DIR}/census-home" PATH="${NODE_DIR}/bin:/usr/bin:/bin" \
      npm ci --registry "${REGISTRY_URL}" --no-audit --no-fund --foreground-scripts --cache "${RUN_DIR}/cache-baseline" </dev/null ) > "${LOGF}" 2>&1
  RC=$?
  node -e '
    const fs=require("fs");const [proj,logf,allow,rc,dir]=process.argv.slice(1);
    const ran=[...new Set([...fs.readFileSync(logf,"utf8").matchAll(/^> (\S+)@\S+ (preinstall|install|postinstall)$/gm)].map(m=>m[1]+":"+m[2]))].sort();
    const flagged=fs.readFileSync(allow,"utf8").split("\n").filter(Boolean);
    const ranPkgs=[...new Set(ran.map(s=>s.split(":")[0]))];
    const gyp=[];const walk=d=>{for(const e of fs.readdirSync(d,{withFileTypes:true})){if(!e.isDirectory())continue;const p=d+"/"+e.name;if(e.name.startsWith("@")){walk(p);continue}if(fs.existsSync(p+"/binding.gyp"))gyp.push(p.split("node_modules/").pop());if(fs.existsSync(p+"/node_modules"))walk(p+"/node_modules")}};
    try{walk(dir+"/node_modules")}catch(e){}
    console.log(JSON.stringify({project:proj,exit_code:+rc,lock_flagged:flagged,scripts_ran:ran,ran_but_not_flagged:ranPkgs.filter(p=>!flagged.includes(p)),flagged_but_not_ran:flagged.filter(p=>!ranPkgs.includes(p)),packages_with_binding_gyp:gyp}));
  ' "$(basename "${D}")" "${LOGF}" "${D}/allowlist.txt" "${RC}" "${D}" | tee -a "${OUT}" >&2
done
