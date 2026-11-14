#!/usr/bin/env bash
# The synthetic victim project: one dependency, the compromised worm package. Optional
# argument "repo-secret" also commits a .env with a canary into the checkout.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
VA="${RUN_DIR}/workspaces/victim-app"
rm -rf "${VA}"; mkdir -p "${VA}"
printf '{ "name": "victim-app", "version": "1.0.0", "private": true,\n  "dependencies": { "@wormlab/worm-sim": "1.0.0" } }\n' > "${VA}/package.json"
[ "${1:-}" = repo-secret ] && printf 'DATABASE_URL=postgres://app:%s@db/app\n' "${CANARY_REPO}" > "${VA}/.env"
true
