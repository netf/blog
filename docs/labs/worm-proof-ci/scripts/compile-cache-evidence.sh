#!/usr/bin/env bash
# Why the sandboxes were ~70 ms slower out of the box: npm (on Node 22) keeps a compile cache in
# $TMPDIR/node-compile-cache. Every sandboxed run starts with an empty or unwritable one.
# Records: denied opens of the cache under Landlock, and `npm --version` startup with a cold
# cache dir versus a warm one. Results: results/compile-cache-evidence.txt
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v strace >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq strace >/dev/null
OUT="${RESULTS}/compile-cache-evidence.txt"; H="$(mktemp -d)"
LL=("${LAB_DIR}/landlock/landlock-run" -r /usr -r /bin -r /lib -r /lib64 -r /etc -r /proc -r /sys -r /dev -r "${NODE_DIR}" -w /dev/null -w "${H}" --)
ms() { local a=(); for i in $(seq 11); do local s; s=$(date +%s%N); "$@" >/dev/null 2>&1; a+=($(( ($(date +%s%N)-s)/1000000 ))); done; printf '%s\n' "${a[@]:1}" | sort -n | sed -n 5p; }
{
  echo "# npm $(npm --version), node $(node --version)"
  env -i HOME="${H}" PATH="${NODE_DIR}/bin:/usr/bin:/bin" strace -f -e trace=openat -o "${H}/st" "${LL[@]}" npm --version >/dev/null 2>&1
  echo "landlock, npm --version: openat() calls denied under /tmp/node-compile-cache: $(grep node-compile-cache "${H}/st" | grep -c EACCES)"
  echo "npm --version median ms, compile cache in a fresh empty dir each run: $(ms bash -c "d=\$(mktemp -d); env -i HOME=${H} PATH=${NODE_DIR}/bin:/usr/bin:/bin NODE_COMPILE_CACHE=\$d npm --version")"
  mkdir -p "${H}/warm"; env -i HOME="${H}" PATH="${NODE_DIR}/bin:/usr/bin:/bin" NODE_COMPILE_CACHE="${H}/warm" npm --version >/dev/null
  echo "npm --version median ms, compile cache kept between runs:            $(ms env -i HOME="${H}" PATH="${NODE_DIR}/bin:/usr/bin:/bin" NODE_COMPILE_CACHE="${H}/warm" npm --version)"
} | tee "${OUT}"
rm -rf "${H}"
