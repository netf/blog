"""Encode each corpus with each embedding model and cache the vectors.

Usage: python scripts/embed.py [dataset ...] [--models bge-small,bge-base]
Writes .cache/emb/<dataset>.<model>.docs.npy and appends wall time to results/index_time.jsonl.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from lab.common import CACHE, DATASETS, EMBEDDERS, EMBEDDERS_FOR, RESULTS, load_dataset  # noqa: E402
from sentence_transformers import SentenceTransformer  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("datasets", nargs="*", default=list(DATASETS))
    ap.add_argument("--models", help="comma list; default: EMBEDDERS_FOR[dataset]")
    args = ap.parse_args()
    out_dir = CACHE / "emb"
    out_dir.mkdir(parents=True, exist_ok=True)
    RESULTS.mkdir(exist_ok=True)
    for ds_name in args.datasets:
        ds = load_dataset(ds_name)
        for key in args.models.split(",") if args.models else EMBEDDERS_FOR[ds_name]:
            path = out_dir / f"{ds_name}.{key}.docs.npy"
            if path.exists():
                print(f"skip {path.name} (cached)", flush=True)
                continue
            e = EMBEDDERS[key]
            model = SentenceTransformer(e.repo, revision=e.revision, device="cpu")
            t0 = time.perf_counter()
            vecs = model.encode(ds.doc_texts, batch_size=32, normalize_embeddings=True, show_progress_bar=False)
            dt = time.perf_counter() - t0
            np.save(path, vecs.astype(np.float32))
            rec = {
                "dataset": ds_name,
                "model": key,
                "docs": len(ds.doc_texts),
                "seconds": round(dt, 1),
                "docs_per_s": round(len(ds.doc_texts) / dt, 2),
                "dim": int(vecs.shape[1]),
                "max_seq_length": model.max_seq_length,
                "torch_threads": torch.get_num_threads(),
            }
            with open(RESULTS / "index_time.jsonl", "a") as f:
                f.write(json.dumps(rec) + "\n")
            print(json.dumps(rec), flush=True)
            del model


if __name__ == "__main__":
    main()
