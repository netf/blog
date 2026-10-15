"""Check that "rerank the top-k" equals "sort the first k of the top-50 cross-encoder scores".

quality.py scores the top-50 once and derives k=10/20 by slicing. That is only valid if a pair's score
does not depend on what else is in its batch (padding). This rescoring of the top-10 and top-20 with
their own predict calls checks the ranking and the score drift.

Usage: python scripts/verify_subset.py <dataset> <embedder> <reranker> [n_queries]
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from lab.common import RERANKERS, RESULTS, load_dataset  # noqa: E402
from scripts.quality import QDIR, read_jsonl_gz  # noqa: E402
from sentence_transformers import CrossEncoder  # noqa: E402


def main() -> None:
    ds_name, emb, rr = sys.argv[1:4]
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 40
    ds = load_dataset(ds_name)
    text = dict(zip(ds.doc_ids, ds.doc_texts))
    qtext = dict(zip(ds.query_ids, ds.query_texts))
    rows = read_jsonl_gz(QDIR / "scores" / f"{ds_name}.{emb}.{rr}.jsonl.gz")[:n]
    r = RERANKERS[rr]
    model = CrossEncoder(r.repo, revision=r.revision, device="cpu")
    max_diff = 0.0
    same_order = 0
    total = 0
    with torch.inference_mode():
        for row in rows:
            for k in (10, 20):
                ids = row["doc_ids"][:k]
                direct = model.predict([(qtext[row["qid"]], text[d]) for d in ids], batch_size=k, show_progress_bar=False)
                sliced = np.array(row["ce_scores"][:k])
                max_diff = max(max_diff, float(np.max(np.abs(direct - sliced))))
                same_order += int(list(np.argsort(-direct, kind="stable")) == list(np.argsort(-sliced, kind="stable")))
                total += 1
    rec = {"dataset": ds_name, "embedder": emb, "reranker": rr, "lists_checked": total, "identical_order": same_order, "max_abs_score_diff": max_diff}
    with open(RESULTS / "quality" / "verify_subset.jsonl", "a") as f:
        f.write(json.dumps(rec) + "\n")
    print(json.dumps(rec))


if __name__ == "__main__":
    main()
