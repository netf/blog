#!/usr/bin/env bash
# Full run in the order I used. Run it on an otherwise idle machine: index time and latency are measured.
# Every step skips work whose output already exists.
set -euo pipefail
cd "$(dirname "$0")/.."
PY="${PYTHON:-python3}"
LAT_RUNS="${LAT_RUNS:-5}"
LAT_QUERIES="${LAT_QUERIES:-100}"
log() { printf '\n=== %s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

log preflight
./scripts/00-preflight.sh

log "embed (SciFact with all three, FiQA with bge-small and bge-base)"
$PY scripts/embed.py scifact
$PY scripts/embed.py fiqa --models bge-small,bge-base

log retrieve
$PY scripts/quality.py retrieve scifact fiqa

rerank() { [ -f "results/quality/scores/$1.$2.$3.jsonl.gz" ] || $PY scripts/quality.py rerank "$1" "$2" "$3"; }
log "rerank: MiniLM-L6 over every retriever, MiniLM-L12 over bge-small"
for ds in scifact fiqa; do
  for emb in bge-small bge-base; do rerank $ds $emb minilm-l6; done
  rerank $ds bge-small minilm-l12
done
rerank scifact bge-large minilm-l6

log "verify that slicing the top-50 scores equals reranking top-k directly"
[ -f results/quality/verify_subset.jsonl ] || {
  $PY scripts/verify_subset.py scifact bge-small minilm-l6 40
  $PY scripts/verify_subset.py fiqa bge-small minilm-l6 40
}

rerankers="bge-small"
for r in minilm-l6 minilm-l12; do for k in 10 20 50; do rerankers+=",bge-small+$r@$k"; done; done
log "latency: retrievers + MiniLM rerankers, $LAT_RUNS runs x $LAT_QUERIES queries"
for ds in fiqa scifact; do
  if [ -f "results/latency/$ds.jsonl" ]; then echo "skip latency $ds (results exist)"; continue; fi
  cfgs="$rerankers,bge-base"
  [ "$ds" = scifact ] && cfgs+=",bge-large"
  for run in $(seq 1 "$LAT_RUNS"); do
    $PY scripts/latency.py $ds "$run" --queries "$LAT_QUERIES" --configs "$cfgs"
  done
done

log analyze
$PY scripts/analyze.py
log done
