"""End-to-end per-query latency on CPU, one query at a time.

Usage: python scripts/latency.py <dataset> <run_id> [--queries 200] [--configs all|<comma list>]

A config is either a plain retriever ("bge-base") or a retriever plus a reranker at depth k
("bge-small+minilm-l6@20"). Every query goes through: encode the query, exact cosine search over the
whole corpus (numpy matmul + argpartition), and, for reranked configs, one CrossEncoder.predict call
over the top-k (batch_size=k). Each stage is timed with perf_counter.

Each run is a fresh process; the config order is shuffled with the run id as the seed, and every
config gets 5 untimed warm-up queries. Results append to results/latency/<dataset>.jsonl.
"""

from __future__ import annotations

import argparse
import json
import platform
import random
import sys
import time
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from lab.common import BGE_QUERY_PROMPT, CACHE, EMBEDDERS, KS, RERANKERS, RESULTS, load_dataset  # noqa: E402
from sentence_transformers import CrossEncoder, SentenceTransformer  # noqa: E402

WARMUP = 5
SAMPLE_SEED = 42


def all_configs() -> list[str]:
    cfgs = list(EMBEDDERS)
    cfgs += [f"bge-small+{r}@{k}" for r in RERANKERS for k in KS]
    return cfgs


def parse(cfg: str) -> tuple[str, str | None, int]:
    if "+" not in cfg:
        return cfg, None, 10
    emb, rest = cfg.split("+")
    rr, k = rest.split("@")
    return emb, rr, int(k)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset")
    ap.add_argument("run_id", type=int)
    ap.add_argument("--queries", type=int, default=200)
    ap.add_argument("--configs", default="all")
    args = ap.parse_args()

    ds = load_dataset(args.dataset)
    rng = random.Random(SAMPLE_SEED)
    qidx = sorted(rng.sample(range(len(ds.query_ids)), min(args.queries, len(ds.query_ids))))
    cfgs = all_configs() if args.configs == "all" else args.configs.split(",")
    random.Random(args.run_id).shuffle(cfgs)

    emb_cache: dict[str, tuple[SentenceTransformer, np.ndarray]] = {}
    rr_cache: dict[str, CrossEncoder] = {}
    out_dir = RESULTS / "latency"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = open(out_dir / f"{args.dataset}.jsonl", "a")

    for cfg in cfgs:
        emb_key, rr_key, k = parse(cfg)
        if emb_key not in emb_cache:
            e = EMBEDDERS[emb_key]
            emb_cache[emb_key] = (
                SentenceTransformer(e.repo, revision=e.revision, device="cpu"),
                np.load(CACHE / "emb" / f"{args.dataset}.{emb_key}.docs.npy"),
            )
        embedder, docs = emb_cache[emb_key]
        reranker = None
        if rr_key:
            if rr_key not in rr_cache:
                r = RERANKERS[rr_key]
                rr_cache[rr_key] = CrossEncoder(r.repo, revision=r.revision, device="cpu")
            reranker = rr_cache[rr_key]

        def one(i: int) -> dict[str, float]:
            t0 = time.perf_counter()
            q = embedder.encode(
                [ds.query_texts[i]], prompt=BGE_QUERY_PROMPT, normalize_embeddings=True, show_progress_bar=False
            )[0]
            t1 = time.perf_counter()
            sims = docs @ q
            top = np.argpartition(-sims, k)[:k]
            top = top[np.argsort(-sims[top])]
            t2 = time.perf_counter()
            t3 = t2
            if reranker is not None:
                pairs = [(ds.query_texts[i], ds.doc_texts[j]) for j in top]
                scores = reranker.predict(pairs, batch_size=k, show_progress_bar=False)
                _ = top[np.argsort(-scores)]
                t3 = time.perf_counter()
            return {"embed_ms": (t1 - t0) * 1e3, "search_ms": (t2 - t1) * 1e3, "rerank_ms": (t3 - t2) * 1e3, "total_ms": (t3 - t0) * 1e3}

        with torch.inference_mode():
            for i in qidx[:WARMUP]:
                one(i)
            t_cfg = time.perf_counter()
            for i in qidx:
                rec = one(i)
                rec.update({"dataset": args.dataset, "run": args.run_id, "config": cfg, "qid": ds.query_ids[i]})
                out.write(json.dumps({k2: (round(v, 3) if isinstance(v, float) else v) for k2, v in rec.items()}) + "\n")
        out.flush()
        print(f"run {args.run_id} {cfg}: {time.perf_counter() - t_cfg:.1f}s for {len(qidx)} queries", flush=True)

    meta = {
        "dataset": args.dataset,
        "run": args.run_id,
        "queries": len(qidx),
        "configs": cfgs,
        "torch_threads": torch.get_num_threads(),
        "torch": torch.__version__,
        "python": platform.python_version(),
    }
    with open(out_dir / "runs.jsonl", "a") as f:
        f.write(json.dumps(meta) + "\n")


if __name__ == "__main__":
    main()
