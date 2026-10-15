#!/usr/bin/env bash
# Full run in the order I used. Run it on an otherwise idle machine: index time and latency are measured.
# Every step skips work whose output already exists, except latency, which appends.
set -euo pipefail
cd "$(dirname "$0")/.."
PY="${PYTHON:-python3}"
LAT_RUNS="${LAT_RUNS:-5}"
LAT_QUERIES="${LAT_QUERIES:-100}"
log() { printf '\n=== %s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

log preflight
./scripts/00-preflight.sh

log "embed (everything except FiQA with bge-large)"
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

LAT_FAST="bge-small,bge-base,bge-large"
for r in minilm-l6 minilm-l12; do for k in 10 20 50; do LAT_FAST+=",bge-small+$r@$k"; done; done
log "latency: retrievers + MiniLM rerankers, $LAT_RUNS runs x $LAT_QUERIES queries"
for ds in fiqa scifact; do
  for run in $(seq 1 "$LAT_RUNS"); do
    $PY scripts/latency.py $ds "$run" --queries "$LAT_QUERIES" --configs "$LAT_FAST"
  done
done
log "latency: bge-reranker-base on FiQA, 3 runs"
for run in 1 2 3; do
  $PY scripts/latency.py fiqa "$run" --queries "$LAT_QUERIES" --configs "bge-small+bge-reranker-base@10,bge-small+bge-reranker-base@20,bge-small+bge-reranker-base@50"
done

log "rerank: bge-reranker-base over bge-small"
for ds in scifact fiqa; do rerank $ds bge-small bge-reranker-base; done

log "embed + retrieve + rerank FiQA with bge-large (the slow one)"
$PY scripts/embed.py fiqa --models bge-large
$PY scripts/quality.py retrieve fiqa
rerank fiqa bge-large minilm-l6

log analyze
$PY scripts/analyze.py
log done
