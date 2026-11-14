#!/usr/bin/env bash
# Report the environment the lab assumes, and fail loudly if a required kernel feature is missing
# instead of silently working around it.
set -uo pipefail
ok=1
say() { printf '%-30s %s\n' "$1" "$2"; }
req() { if eval "$2" >/dev/null 2>&1; then say "$1" ok; else say "$1" MISSING; ok=0; fi; }
say cpu "$(nproc)"
say memory "$(free -h | awk '/Mem:/{print $2" total, "$7" available"}')"
say virt "$(systemd-detect-virt 2>/dev/null || echo unknown)"
say kernel "$(uname -r)"
say cgroup "$(stat -fc %T /sys/fs/cgroup)"
req "landlock LSM active" "grep -q landlock /sys/kernel/security/lsm"
say "landlock ABI" "$(python3 -c 'import ctypes;print(ctypes.CDLL(None).syscall(444,None,0,1))' 2>/dev/null)"
req "unprivileged user namespaces" "unshare -Urn true"
for t in node npm bwrap nft ip openssl gcc bc; do
  if command -v "$t" >/dev/null; then
    case "$t" in ip) v="$(ip -V)";; openssl) v="$(openssl version)";; gcc) v="$(gcc -dumpfullversion)";; bc) v="$(bc --version | head -1)";; *) v="$($t --version 2>&1 | head -1)";; esac
    say "$t" "$v"
  else say "$t" "not installed (reproduce.sh installs it)"; fi
done
req "netns + nft (sudo)" "sudo ip netns add _pf && sudo ip netns exec _pf nft 'add table inet t' && sudo ip netns del _pf"
[ "$ok" = 1 ] && echo "preflight: ok" || { echo "preflight: MISSING features above" >&2; exit 1; }
