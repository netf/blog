#!/usr/bin/env bash
# better-sqlite3 sets "gypfile": false and has no install script, and its lockfile entry has no
# hasInstallScript. Does npm run node-gyp for it anyway? Compared for `npm ci` (with the committed
# lockfile) and `npm install` (no lockfile). Results: results/gyp-ci-vs-install.txt
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SRC="${LAB_DIR}/corpus/projects/better-sqlite3"; OUT="${RESULTS}/gyp-ci-vs-install.txt"
{
  echo "# npm $(npm --version); better-sqlite3 $(node -e 'console.log(require(process.argv[1]).packages["node_modules/better-sqlite3"].version)' "${SRC}/package-lock.json")"
  echo "registry metadata: $(curl -fsS "${REGISTRY_URL}/better-sqlite3" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const j=JSON.parse(d),v=j.versions[j["dist-tags"].latest];console.log(JSON.stringify({gypfile:v.gypfile,hasInstallScript:v.hasInstallScript??null,install:v.scripts.install??null}))})')"
  echo "lockfile entry hasInstallScript: $(node -e 'console.log(require(process.argv[1]).packages["node_modules/better-sqlite3"].hasInstallScript??false)' "${SRC}/package-lock.json")"
  for M in ci install; do
    W="$(mktemp -d)"; cp "${SRC}/package.json" "${W}/"; [ "${M}" = ci ] && cp "${SRC}/package-lock.json" "${W}/"
    R="$( cd "${W}" && env -i HOME="${W}" PATH="${NODE_DIR}/bin:/usr/bin:/bin" npm "${M}" --registry "${REGISTRY_URL}" --no-audit --no-fund \
          --foreground-scripts --cache "${RUN_DIR}/cache-baseline" </dev/null 2>&1 | grep -A1 -E '^> better-sqlite3@' | tr '\n' ' ' || true )"
    echo "npm ${M}: ${R:-no lifecycle script ran for better-sqlite3}"
    rm -rf "${W}"
  done
} | tee "${OUT}"
