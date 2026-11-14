#!/usr/bin/env bash
# Negative controls for failure test 3: install with --ignore-scripts, run the functional smoke,
# delete the prebuilt binary the package actually loads, run it again. If the second run still
# passed, the smoke test would prove nothing. (sharp falls back to its WebAssembly build, so both go.) Results: results/native-controls.jsonl
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OUT="${RESULTS}/native-controls.jsonl"; : > "${OUT}"
sudo bash "${LAB_DIR}/scripts/netns-up.sh" allowlist >/dev/null 2>&1
run() { ( cd "$1" && env -i PATH="${NODE_DIR}/bin:/usr/bin:/bin" HOME=/tmp node --input-type=commonjs -e "$2" ) >/dev/null 2>&1 && echo pass || echo fail; }
ctl() { # project path-under-node_modules code
  local D="${LAB_DIR}/corpus/projects/$1"; rm -rf "${D}/node_modules"
  bash "${LAB_DIR}/scripts/stage-install.sh" --mode hardened --project "${D}" --scripts off --cache "${RUN_DIR}/cache-hardened"
  local A; A="$(run "${D}" "$3")"; for p in $2; do rm -rf "${D}/node_modules/${p}"; done; local B; B="$(run "${D}" "$3")"
  echo "{\"project\":\"$1\",\"binary_removed\":\"$2\",\"smoke_intact\":\"${A}\",\"smoke_after_removal\":\"${B}\"}" | tee -a "${OUT}" >&2
}
ctl esbuild        "@esbuild/linux-x64"                      "process.exit(require('esbuild').transformSync('let x=1+1').code?0:1)"
ctl bcrypt         "bcrypt/prebuilds"                        "const b=require('bcrypt');process.exit(b.compareSync('pw',b.hashSync('pw',4))?0:1)"
ctl swc-core       "@swc/core-linux-x64-gnu"                 "process.exit(require('@swc/core').transformSync('let x=1+1').code?0:1)"
ctl sharp          "@img/sharp-linux-x64 @img/sharp-wasm32"   "require('sharp')({create:{width:2,height:2,channels:3,background:'#123'}}).png().toBuffer().then(b=>process.exit(b.length?0:1),()=>process.exit(1))"
ctl better-sqlite3 "better-sqlite3/prebuilds/linux-x64.node" "const db=new (require('better-sqlite3'))(':memory:');db.exec('create table t(x)');process.exit(0)"
ctl jest           "@parcel/watcher-linux-x64-glibc"         "const w=require('@parcel/watcher'),fs=require('fs'),d=fs.mkdtempSync('/tmp/pw-');w.subscribe(d,(e,ev)=>{if(ev.length)process.exit(0)}).then(()=>setTimeout(()=>fs.writeFileSync(d+'/x','1'),200));setTimeout(()=>process.exit(1),5000)"
