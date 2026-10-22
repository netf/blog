#!/usr/bin/env bash
# Environment preflight (report.md section 6). Writes results/environment-raw.txt.
# Fails loudly if a required piece is missing instead of working around it.
set -u
cd "$(dirname "$0")/.."
out=results/environment-raw.txt
mkdir -p results
missing=()

{
  echo "# preflight $(date -u +%FT%TZ)"
  echo "## compute"
  echo "nproc: $(nproc)"
  free -h
  echo "balloon pages (inflate-deflate): $(awk '/balloon_inflate/{i=$2}/balloon_deflate/{d=$2}END{print i-d}' /proc/vmstat)"
  df -h "$PWD"
  echo "virt: $(systemd-detect-virt 2>/dev/null || echo unknown)"
  echo "pid1: $(ps -o comm= -p 1)"
  lscpu | grep -E 'Model name|Thread|Core|Socket|MHz'
  echo "cpu flags of interest: $(grep -o -w 'aes\|vaes\|avx2\|avx512f\|sha_ni\|pclmulqdq' /proc/cpuinfo | sort -u | tr '\n' ' ')"
  echo "## kernel"
  uname -r
  echo "cgroup fs: $(stat -fc %T /sys/fs/cgroup)"
  echo "ulimit -n: $(ulimit -n)"
  echo "## tools"
  python3 --version
  command -v docker >/dev/null && docker version --format '{{.Server.Version}}' || echo "docker: not installed (not required by this lab)"
  if command -v pg_config >/dev/null || [ -x /usr/lib/postgresql/18/bin/postgres ]; then
    /usr/lib/postgresql/18/bin/postgres --version
  else
    echo "postgres: MISSING"
  fi
  if [ -x .venv/bin/python ]; then
    .venv/bin/pip freeze
  else
    echo "venv: MISSING (run scripts/01-setup.sh)"
  fi
  echo "## network"
  for u in https://pypi.org/simple/tink/ https://apt.postgresql.org/pub/repos/apt/; do
    echo "$u -> $(curl -s -o /dev/null -w '%{http_code}' -m 10 "$u")"
  done
} > "$out" 2>&1

grep -q 'aes' <<<"$(grep -o -w aes /proc/cpuinfo | head -1)" || missing+=("AES-NI (Tink AES-SIV would run in software)")
[ "$(nproc)" -ge 4 ] || missing+=("at least 4 vCPUs")
avail_gb=$(df -BG --output=avail "$PWD" | tail -1 | tr -dc 0-9)
[ "$avail_gb" -ge 40 ] || missing+=("40 GB free disk (have ${avail_gb} GB)")

cat "$out"
if [ ${#missing[@]} -gt 0 ]; then
  printf 'PREFLIGHT BLOCKER: %s\n' "${missing[@]}"
  exit 1
fi
echo "preflight ok"
