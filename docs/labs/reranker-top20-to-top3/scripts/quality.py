"""Retrieval quality: embedder top-100, then cross-encoder scores for the top-50.

Usage:
  python scripts/quality.py retrieve [dataset ...]
  python scripts/quality.py rerank <dataset> <embedder> <reranker>

`retrieve` writes results/quality/candidates/<dataset>.<embedder>.jsonl.gz (top-100 ids and cosine scores).
`rerank` scores the top-50 candidates of every query in one CrossEncoder.predict call per query and writes
results/quality/scores/<dataset>.<embedder>.<reranker>.jsonl.gz. Reranking at k=10/20/50 is then a sort of
the first k of those scores (see verify_subset.py for the check that this equals reranking k directly).
"""

from __future__ import annotations

import gzip
import json
import sys
import time
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from lab.common import (  # noqa: E402
    BGE_QUERY_PROMPT,
    CACHE,
    DATASETS,
    EMBEDDERS,
    RERANKERS,
    RESULTS,
    load_dataset,
)
from sentence_transformers import CrossEncoder, SentenceTransformer  # noqa: E402

TOP_N = 100
RERANK_DEPTH = 50
QDIR = RESULTS / "quality"


def write_jsonl_gz(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(path, "wt") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")


def read_jsonl_gz(path: Path) -> list[dict]:
    with gzip.open(path, "rt") as f:
        return [json.loads(line) for line in f]


def retrieve(ds_name: str) -> None:
    ds = load_dataset(ds_name)
    for key, e in EMBEDDERS.items():
        out = QDIR / "candidates" / f"{ds_name}.{key}.jsonl.gz"
        if out.exists():
            print(f"skip {out.name}", flush=True)
            continue
        emb_path = CACHE / "emb" / f"{ds_name}.{key}.docs.npy"
        if not emb_path.exists():
            print(f"skip {out.name}: no embeddings yet (run embed.py)", flush=True)
            continue
        docs = np.load(emb_path)
        model = SentenceTransformer(e.repo, revision=e.revision, device="cpu")
        q = model.encode(ds.query_texts, prompt=BGE_QUERY_PROMPT, batch_size=32, normalize_embeddings=True)
        sims = q @ docs.T
        rows = []
        for i, qid in enumerate(ds.query_ids):
            top = np.argpartition(-sims[i], TOP_N)[:TOP_N]
            top = top[np.argsort(-sims[i][top], kind="stable")]
            rows.append(
                {
                    "qid": qid,
                    "doc_ids": [ds.doc_ids[j] for j in top],
                    "scores": [round(float(sims[i][j]), 6) for j in top],
                }
            )
        write_jsonl_gz(out, rows)
        print(f"wrote {out.name}", flush=True)


def rerank(ds_name: str, emb_key: str, rr_key: str) -> None:
    ds = load_dataset(ds_name)
    text = dict(zip(ds.doc_ids, ds.doc_texts))
    qtext = dict(zip(ds.query_ids, ds.query_texts))
    cands = read_jsonl_gz(QDIR / "candidates" / f"{ds_name}.{emb_key}.jsonl.gz")
    r = RERANKERS[rr_key]
    model = CrossEncoder(r.repo, revision=r.revision, device="cpu")
    rows = []
    t0 = time.perf_counter()
    with torch.inference_mode():
        for n, c in enumerate(cands):
            ids = c["doc_ids"][:RERANK_DEPTH]
            pairs = [(qtext[c["qid"]], text[d]) for d in ids]
            scores = model.predict(pairs, batch_size=RERANK_DEPTH, show_progress_bar=False)
            rows.append({"qid": c["qid"], "doc_ids": ids, "ce_scores": [round(float(s), 6) for s in scores]})
            if n % 100 == 0:
                print(f"{ds_name} {emb_key} {rr_key}: {n}/{len(cands)} {time.perf_counter() - t0:.0f}s", flush=True)
    dt = time.perf_counter() - t0
    out = QDIR / "scores" / f"{ds_name}.{emb_key}.{rr_key}.jsonl.gz"
    write_jsonl_gz(out, rows)
    meta = {
        "dataset": ds_name,
        "embedder": emb_key,
        "reranker": rr_key,
        "queries": len(rows),
        "pairs": len(rows) * RERANK_DEPTH,
        "seconds": round(dt, 1),
        "max_length": model.max_length,
    }
    with open(QDIR / "rerank_runs.jsonl", "a") as f:
        f.write(json.dumps(meta) + "\n")
    print(json.dumps(meta), flush=True)


if __name__ == "__main__":
    cmd, *rest = sys.argv[1:]
    if cmd == "retrieve":
        for d in rest or list(DATASETS):
            retrieve(d)
    elif cmd == "rerank":
        rerank(*rest)
    else:
        raise SystemExit(__doc__)
