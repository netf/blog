#!/usr/bin/env bash
# The publish stage: the ONLY stage that holds the registry credential. Same egress-allowlist
# netns and bubblewrap sandbox as the install stage, --ignore-scripts, and the credential comes
# in through a read-only bound HOME. It never executes dependency code.
#   stage-publish.sh --project DIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ "$1" = --project ] && PROJECT="$(cd "$2" && pwd)"
U="$(id -u)"; G="$(id -g)"
PUBHOME="${RUN_DIR}/publish-home"; rm -rf "${PUBHOME}"; mkdir -p "${PUBHOME}"
printf 'registry=%s/\n//%s:%s/:_auth=%s\n' "${REGISTRY_URL}" "${HOST_IP}" "${REGISTRY_PORT}" "$(cat "${RUN_DIR}/publish_token")" > "${PUBHOME}/.npmrc"
sudo ip netns exec "${NETNS}" setpriv --reuid "${U}" --regid "${G}" --clear-groups \
  bwrap --unshare-user --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup \
    --die-with-parent --new-session \
    --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /sbin /sbin \
    --ro-bind-try /lib /lib --ro-bind-try /lib64 /lib64 --ro-bind /etc /etc \
    --ro-bind "${NODE_DIR}" "${NODE_DIR}" --proc /proc --dev /dev --tmpfs /tmp \
    --ro-bind "${PUBHOME}" "${PUBHOME}" --bind "${PROJECT}" "${PROJECT}" \
    --chdir "${PROJECT}" --clearenv \
    --setenv HOME "${PUBHOME}" --setenv PATH "${NODE_DIR}/bin:/usr/bin:/bin" \
    npm publish --registry "${REGISTRY_URL}" --ignore-scripts --auth-type=legacy --loglevel=error </dev/null
