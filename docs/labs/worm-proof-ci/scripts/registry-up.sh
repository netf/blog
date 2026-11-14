#!/usr/bin/env bash
# Start the local Verdaccio registry, create the publish account, and seed the
# already-compromised dependency (@wormlab/worm-sim) the way the real worm arrived: as a
# normal package version on the registry. Needs the veth (netns-up.sh) to exist first.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
VERDACCIO="${LAB_DIR}/registry/node_modules/.bin/verdaccio"
if [ ! -x "${VERDACCIO}" ]; then
  mkdir -p "${LAB_DIR}/registry"
  ( cd "${LAB_DIR}/registry" && echo '{"private":true}' > package.json \
    && npm install --no-audit --no-fund --loglevel=error verdaccio@6.10.7 </dev/null )
fi
REG="${RUN_DIR}/registry"
mkdir -p "${REG}/storage"
cp "${LAB_DIR}/config/verdaccio.yaml" "${REG}/config.yaml"
# apr1 hashes are accepted by verdaccio's htpasswd plugin.
printf '%s:%s\n' "${PUBLISH_USER}" "$(openssl passwd -apr1 -salt wormsalt "${PUBLISH_PASS}")" > "${REG}/htpasswd"

[ -f "${RUN_DIR}/verdaccio.pid" ] && kill "$(cat "${RUN_DIR}/verdaccio.pid")" 2>/dev/null; pkill -x verdaccio 2>/dev/null || true; sleep 0.5  # verdaccio renames its process
# setsid + </dev/null so the daemon never holds the caller's pipe open.
( cd "${REG}" && setsid "${VERDACCIO}" --config config.yaml --listen "0.0.0.0:${REGISTRY_PORT}" \
    </dev/null > "${REG}/stdout.log" 2>&1 & echo $! > "${RUN_DIR}/verdaccio.pid" )
for i in $(seq 1 60); do
  curl -fsS "${REGISTRY_URL}/-/ping" >/dev/null 2>&1 && break
  sleep 0.5
  [ "$i" = 60 ] && { echo "verdaccio did not start" >&2; cat "${REG}/stdout.log" >&2; exit 1; }
done

# Registration is disabled, so the publish account authenticates with HTTP Basic against
# htpasswd. Only the publish stage (and the baseline victim, which models a normal CI job
# with a publish token in scope) ever sees this credential.
PUB_AUTH="$(printf '%s:%s' "${PUBLISH_USER}" "${PUBLISH_PASS}" | base64 -w0)"
echo "${PUB_AUTH}" > "${RUN_DIR}/publish_token"
printf 'registry=%s/\n//%s:%s/:_auth=%s\n' "${REGISTRY_URL}" "${HOST_IP}" "${REGISTRY_PORT}" "${PUB_AUTH}" > "${RUN_DIR}/seed.npmrc"
( cd "${LAB_DIR}/worm/worm-sim" && npm publish --registry "${REGISTRY_URL}" --userconfig "${RUN_DIR}/seed.npmrc" \
    --auth-type=legacy </dev/null >/dev/null 2>&1 ) && log "seeded @wormlab/worm-sim" || log "worm already seeded"
log "verdaccio up at ${REGISTRY_URL}"
