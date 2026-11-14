#!/usr/bin/env bash
# Extract the copy-paste install wrapper from the blog post verbatim and run it against two corpus
# projects (no allowlist; esbuild allowlisted), then probe the jail it builds. Needs the registry
# up. Temporarily replaces the lab's own veth (same address). Results: results/post-wrapper-check.txt
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
POST="${LAB_DIR}/../../../src/content/blog/worm-proof-ci.md"; WRAP="${RUN_DIR}/post-wrapper.sh"
awk '/^```bash$/{b=1;buf="";next} /^```$/{if(b && buf ~ /sandbox\(\)/){print buf}; b=0; next} b{buf=buf $0 "\n"}' "${POST}" > "${WRAP}"
reset_net() { sudo ip netns del ci 2>/dev/null || true; sudo ip link del veth-h 2>/dev/null || true; sudo ip netns del "${NETNS}" 2>/dev/null || true; sudo ip link del "${VETH_HOST}" 2>/dev/null || true; }
{
  echo "# wrapper extracted from the post: $(wc -l < "${WRAP}") lines"
  for CASE in express: esbuild:esbuild; do
    P="${CASE%%:*}"; A="${CASE#*:}"; reset_net
    W="$(mktemp -d)"; cp -r "${LAB_DIR}/corpus/projects/${P}/." "${W}/"; rm -rf "${W}/node_modules"; mkdir -p "${W}/ci"
    [ -n "${A}" ] && echo "${A}" > "${W}/ci/allowlist.txt"
    ( cd "${W}" && bash "${WRAP}" ) > "${RUN_DIR}/post-wrapper.log" 2>&1; RC=$?
    echo "${P} allowlist=[${A}] exit=${RC} installed_top_level=$(ls "${W}/node_modules" | wc -l)"
    if [ "${P}" = express ]; then
      eval "$(sed -n '/^sandbox() {/,/^}/p' "${WRAP}")"; CACHE="${W}/.npm-cache"; cd "${W}"
      echo "  registry from jail: $(sandbox node -e "require('http').get('http://${HOST_IP}:${REGISTRY_PORT}/-/ping',r=>console.log(r.statusCode)).on('error',e=>console.log(e.code))" 2>&1)"
      echo "  C2 tcp/${HTTP_SINK_PORT} from jail: $(sandbox node -e "const r=require('http').get({host:'${HOST_IP}',port:${HTTP_SINK_PORT},timeout:1500},()=>console.log('OPEN'));r.on('timeout',()=>{console.log('blocked (timeout)');process.exit()});r.on('error',e=>console.log('blocked',e.code))" 2>&1)"
      echo "  udp/53 to 1.1.1.1 from jail: $(sandbox node -e "require('dgram').createSocket('udp4').send('x',53,'1.1.1.1',e=>{console.log(e?'blocked '+e.code:'SENT');process.exit()})" 2>&1)"
      echo "  entries in \$HOME: $(sandbox sh -c 'ls -A "$HOME" | wc -l'); env vars containing TOKEN: $(sandbox sh -c 'env | grep -c TOKEN || true')"
      cd "${LAB_DIR}"
    fi
    rm -rf "${W}"
  done
} | tee "${RESULTS}/post-wrapper-check.txt"
reset_net; sudo bash "${LAB_DIR}/scripts/netns-up.sh" allowlist >/dev/null
