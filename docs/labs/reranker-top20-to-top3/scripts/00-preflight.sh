#!/usr/bin/env bash
# Records the machine and checks that everything the lab needs is reachable.
# Exits non-zero (and says why) if a requirement is missing instead of working around it.
set -uo pipefail
cd "$(dirname "$0")/.."
PY="${PYTHON:-python3}"
fail=0
say() { printf '%s\n' "$*"; }
need() { say "BLOCKER: $*"; fail=1; }

{
  say "# preflight $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  say "## compute"
  say "virt: $(systemd-detect-virt 2>/dev/null || echo unknown)"
  say "kernel: $(uname -r)"
  grep -m1 PRETTY_NAME /etc/os-release
  say "nproc: $(nproc)"
  lscpu | grep -E '^(Model name|Thread|Core|Socket)'
  say "isa: $(grep -o -w -E 'avx2|avx512f|avx512_vnni|avx512_bf16|amx_tile' /proc/cpuinfo | sort -u | tr '\n' ' ')"
  free -h
  grep -E 'MemTotal|MemAvailable' /proc/meminfo
  df -h . | tail -1
  say "## gpu"
  if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then nvidia-smi -L; else say "none (no nvidia-smi / no /dev/nvidia*)"; fi
  say "## python"
  "$PY" --version
  "$PY" - <<'EOF'
import importlib, platform
for m in ["torch", "transformers", "sentence_transformers", "huggingface_hub", "numpy", "tokenizers"]:
    try:
        print(f"{m}: {importlib.import_module(m).__version__}")
    except Exception as e:
        print(f"{m}: MISSING ({e})")
try:
    import torch
    print("torch threads:", torch.get_num_threads(), "| cuda available:", torch.cuda.is_available())
    print("torch config:", " ".join(l.strip() for l in torch.__config__.show().splitlines() if "CPU capability" in l))
except Exception:
    pass
EOF
  say "## network"
  for u in https://huggingface.co/api/models/BAAI/bge-small-en-v1.5 https://huggingface.co/api/datasets/mteb/scifact https://pypi.org/simple/sentence-transformers/; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$u")
    say "$u -> $code"
  done
  say "## limits"
  say "ulimit -n: $(ulimit -n)"
} 2>&1 | tee results/environment.txt

avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
[ "$avail_kb" -lt 3500000 ] && need "less than 3.5 GB RAM available; bge-large + bge-reranker-base will not fit"
"$PY" -c 'import sentence_transformers, torch' 2>/dev/null || need "sentence-transformers/torch not importable (pip install -r requirements.txt)"
curl -sf -m 20 -o /dev/null https://huggingface.co/api/datasets/mteb/scifact || need "cannot reach huggingface.co (models and datasets come from there)"
[ "$fail" -eq 0 ] && say "preflight OK" || exit 1
