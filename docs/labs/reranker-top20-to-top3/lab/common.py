"""Shared config, data loading and metrics for the reranker lab.

Every model and dataset is pinned to a Hugging Face commit so a rerun downloads exactly what I used.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from huggingface_hub import hf_hub_download

LAB_DIR = Path(__file__).resolve().parent.parent
RESULTS = LAB_DIR / "results"
CACHE = Path(os.environ.get("RR_CACHE", LAB_DIR / ".cache"))

DATASETS = {
    "scifact": ("mteb/scifact", "cf10ab6856b15b0e670ef8ae5dae4e266c12d035"),
    "fiqa": ("mteb/fiqa", "5e59eeb3a7df6b85882112b747008547c21587ea"),
}

BGE_QUERY_PROMPT = "Represent this sentence for searching relevant passages: "


@dataclass(frozen=True)
class Embedder:
    key: str
    repo: str
    revision: str
    params_m: int


@dataclass(frozen=True)
class Reranker:
    key: str
    repo: str
    revision: str
    params_m: int


EMBEDDERS = {
    e.key: e
    for e in [
        Embedder("bge-small", "BAAI/bge-small-en-v1.5", "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a", 33),
        Embedder("bge-base", "BAAI/bge-base-en-v1.5", "a5beb1e3e68b9ab74eb54cfd186867f64f240e1a", 109),
        Embedder("bge-large", "BAAI/bge-large-en-v1.5", "d4aa6901d3a41ba39fb536a557fa166f842b0e09", 335),
    ]
}

RERANKERS = {
    r.key: r
    for r in [
        Reranker("minilm-l6", "cross-encoder/ms-marco-MiniLM-L6-v2", "233902d25c440f23af6f7d6e94d2946bac0bee0a", 23),
        Reranker("minilm-l12", "cross-encoder/ms-marco-MiniLM-L12-v2", "7b0235231ca2674cb8ca8f022859a6eba2b1c968", 33),
        Reranker("bge-reranker-base", "BAAI/bge-reranker-base", "2cfc18c9415c912f9d8155881c133215df768a70", 278),
    ]
}

KS = (10, 20, 50)


def _read_jsonl(path: str) -> list[dict]:
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


@dataclass
class Dataset:
    name: str
    doc_ids: list[str]
    doc_texts: list[str]
    query_ids: list[str]
    query_texts: list[str]
    qrels: dict[str, dict[str, int]]


def load_dataset(name: str) -> Dataset:
    """BEIR test split. Documents are 'title text' joined with a space, as in BEIR's and MTEB's own
    evaluation; queries without a positive judgement are dropped."""
    repo, rev = DATASETS[name]
    get = lambda f: hf_hub_download(repo, f, repo_type="dataset", revision=rev, cache_dir=CACHE / "hf")
    corpus = _read_jsonl(get("corpus.jsonl"))
    queries = {q["_id"]: q["text"] for q in _read_jsonl(get("queries.jsonl"))}
    qrels: dict[str, dict[str, int]] = {}
    with open(get("qrels/test.tsv")) as f:
        next(f)
        for line in f:
            qid, did, score = line.rstrip("\n").split("\t")
            if int(score) > 0:
                qrels.setdefault(qid, {})[did] = int(score)
    doc_ids = [d["_id"] for d in corpus]
    doc_texts = [(d["title"].strip() + " " + d["text"]).strip() if d.get("title") else d["text"] for d in corpus]
    qids = sorted(q for q in qrels if q in queries)
    return Dataset(name, doc_ids, doc_texts, qids, [queries[q] for q in qids], qrels)


def query_metrics(ranked: list[str], rel: dict[str, int]) -> dict[str, float]:
    """Per-query metrics for one ranked list of doc ids.

    recall@k is BEIR's definition (share of the query's relevant docs found in the top k);
    hit@k is 1 if at least one relevant doc is in the top k; mrr@10 uses the first relevant doc.
    """
    n_rel = len(rel)
    out: dict[str, float] = {}
    for k in (1, 3, 5, 10, 20, 50, 100):
        found = sum(1 for d in ranked[:k] if d in rel)
        out[f"recall@{k}"] = found / n_rel
        out[f"hit@{k}"] = float(found > 0)
    rr = 0.0
    for i, d in enumerate(ranked[:10]):
        if d in rel:
            rr = 1.0 / (i + 1)
            break
    out["mrr@10"] = rr
    # Linear gain, as in pytrec_eval (which BEIR uses); both datasets here have binary labels anyway.
    dcg = sum(rel[d] / np.log2(i + 2) for i, d in enumerate(ranked[:10]) if d in rel)
    ideal = sorted(rel.values(), reverse=True)[:10]
    idcg = sum(g / np.log2(i + 2) for i, g in enumerate(ideal))
    out["ndcg@10"] = dcg / idcg
    first = next((i + 1 for i, d in enumerate(ranked) if d in rel), None)
    out["first_rel_rank"] = float(first) if first else float("nan")
    return out
