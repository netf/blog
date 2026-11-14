#!/usr/bin/env bash
# Helpers shared by run-attack.sh and failure-tests.sh.
VA="${RUN_DIR}/workspaces/victim-app"
versions99() { curl -fsS "${REGISTRY_URL}/@wormlab%2fworm-sim" 2>/dev/null \
  | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{console.log(Object.keys(JSON.parse(d).versions).filter(v=>v.startsWith("99.")).length)}catch(e){console.log(0)}})'; }
# distinct canaries that reached the sink over one channel (http|dns)
sink_canaries() { { grep "\"kind\":\"$1\"" "${RUN_DIR}/sink.log" 2>/dev/null | grep -o 'CANARY-[A-Z]*-[0-9a-f]\{16\}' | sort -u | wc -l; } || true; }
sink_has() { grep -q "$1" "${RUN_DIR}/sink.log" 2>/dev/null && echo 1 || echo 0; }
reset_victim() { pkill -f worm-bg- 2>/dev/null || true; bash "${LAB_DIR}/scripts/make-victim.sh" "${1:-}"; rm -f "${RUN_DIR}/workspaces/WORM_ESCAPE.txt"; bash "${LAB_DIR}/scripts/sink-up.sh"; }
worm_field() { node -e 'try{const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n")[0]);console.log(eval("r."+process.argv[2])??"")}catch(e){console.log("")}' "${RUN_DIR}/reports/worm-$1.jsonl" "$2"; }
scripts_for() { [ "$1" = hardened ] && echo off || echo on; }
