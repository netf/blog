#!/usr/bin/env bash
# For each package in corpus.txt: a one-dependency project, its full tree resolved against the
# local registry into a committed package-lock.json, its exact version in versions.txt, and its
# allowlist (packages the lockfile marks hasInstallScript) in allowlist.txt.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="${LAB_DIR}/corpus/projects"; mkdir -p "${PROJ}"
: > "${LAB_DIR}/corpus/versions.txt"
grep -vE '^\s*#|^\s*$' "${LAB_DIR}/corpus/corpus.txt" | while read -r PKG; do
  SLUG="$(echo "${PKG}" | sed 's#^@##; s#/#-#g')"; D="${PROJ}/${SLUG}"; mkdir -p "${D}"
  if [ ! -f "${D}/package-lock.json" ]; then
    printf '{ "name": "corpus-%s", "version": "1.0.0", "private": true,\n  "dependencies": { "%s": "latest" } }\n' "${SLUG}" "${PKG}" > "${D}/package.json"
    ( cd "${D}" && npm install --package-lock-only --registry "${REGISTRY_URL}" --maxsockets 8 \
        --no-audit --no-fund --loglevel=error </dev/null ) || { log "FAILED ${PKG}"; continue; }
  fi
  node -e 'const l=require(process.argv[1]);console.log(process.argv[2],l.packages["node_modules/"+process.argv[2]].version)' "${D}/package-lock.json" "${PKG}" >> "${LAB_DIR}/corpus/versions.txt"
  node "${LAB_DIR}/scripts/detect-allowlist.cjs" "${D}/package-lock.json" > "${D}/allowlist.txt"
  log "locked ${PKG}"
done
