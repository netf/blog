#!/usr/bin/env bash
# Build the "victim" HOME the baseline install stage sees: fake canary tokens in the usual
# places, plus a functional credential for the LOCAL registry, which models a normal CI job
# that has a publish token in scope.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
VH="${RUN_DIR}/victim-home"
rm -rf "${VH}"; mkdir -p "${VH}/.aws" "${VH}/.config/gh"
cat > "${VH}/.npmrc" <<NPMRC
registry=${REGISTRY_URL}/
//${HOST_IP}:${REGISTRY_PORT}/:_auth=$(cat "${RUN_DIR}/publish_token")
//registry.npmjs.org/:_authToken=${CANARY_NPM}
NPMRC
printf '[default]\naws_access_key_id = AKIA0000CANARY000000\naws_secret_access_key = %s\n' "${CANARY_AWS}" > "${VH}/.aws/credentials"
printf 'github.com:\n    oauth_token: %s\n    user: victim\n' "${CANARY_GH}" > "${VH}/.config/gh/hosts.yml"
printf 'GITHUB_TOKEN=%s\nAWS_SECRET_ACCESS_KEY=%s\nNPM_TOKEN=%s\n' "${CANARY_GH}" "${CANARY_AWS}" "${CANARY_NPM}" > "${RUN_DIR}/victim.env"
log "planted canaries in victim-home + victim.env"
