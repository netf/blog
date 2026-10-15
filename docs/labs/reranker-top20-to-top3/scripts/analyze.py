"""Turn raw results into the tables used in the post.

Reads results/quality/{candidates,scores}/*.jsonl.gz, results/latency/*.jsonl and results/index_time.jsonl.
Writes results/summary.md, results/summary.json and results/quality/per_query.jsonl.gz.

Quality is deterministic for a fixed model and input (checked by verify_subset.py and by rerunning), so
its uncertainty is a paired bootstrap over queries (10,000 resamples, seed 0), not run-to-run spread.
Latency spread is across fresh-process runs.
"""

from __future__ import annotations

import gzip
import json
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from lab.common import DATASETS, EMBEDDERS, KS, RERANKERS, RESULTS, load_dataset, query_metrics  # noqa: E402

QDIR = RESULTS / "quality"
METRICS = ["recall@3", "recall@10", "hit@3", "mrr@10", "ndcg@10"]
B = 10_000


def read_gz(path: Path) -> list[dict]:
    with gzip.open(path, "rt") as f:
        return [json.loads(line) for line in f]


def reranked_order(cand_ids: list[str], score_row: dict, k: int) -> list[str]:
    ids = score_row["doc_ids"][:k]
    assert ids == cand_ids[:k]
    s = np.array(score_row["ce_scores"][:k])
    order = np.argsort(-s, kind="stable")
    return [ids[i] for i in order] + cand_ids[k:]


def boot_ci(diff: np.ndarray, rng: np.random.Generator) -> tuple[float, float]:
    idx = rng.integers(0, len(diff), size=(B, len(diff)))
    means = diff[idx].mean(axis=1)
    return float(np.percentile(means, 2.5)), float(np.percentile(means, 97.5))


def quality(ds_name: str, rng: np.random.Generator) -> dict:
    ds = load_dataset(ds_name)
    per_cfg: dict[str, dict[str, dict[str, float]]] = {}
    cands: dict[str, dict[str, list[str]]] = {}
    for emb in EMBEDDERS:
        p = QDIR / "candidates" / f"{ds_name}.{emb}.jsonl.gz"
        if not p.exists():
            continue
        cands[emb] = {r["qid"]: r["doc_ids"] for r in read_gz(p)}
        per_cfg[emb] = {q: query_metrics(ids, ds.qrels[q]) for q, ids in cands[emb].items()}
    for p in sorted((QDIR / "scores").glob(f"{ds_name}.*.jsonl.gz")):
        _, emb, rr, *_ = p.name.split(".")
        rows = {r["qid"]: r for r in read_gz(p)}
        for k in KS:
            cfg = f"{emb}+{rr}@{k}"
            per_cfg[cfg] = {
                q: query_metrics(reranked_order(cands[emb][q], rows[q], k), ds.qrels[q]) for q in cands[emb]
            }

    qids = ds.query_ids
    table = {}
    for cfg, pq in per_cfg.items():
        table[cfg] = {m: float(np.mean([pq[q][m] for q in qids])) for m in METRICS}
        emb = cfg.split("+")[0]
        table[cfg]["retriever_recall@20"] = float(np.mean([per_cfg[emb][q]["recall@20"] for q in qids]))
        table[cfg]["retriever_recall@50"] = float(np.mean([per_cfg[emb][q]["recall@50"] for q in qids]))

    def diff(a: str, b: str, m: str) -> dict:
        d = np.array([per_cfg[a][q][m] - per_cfg[b][q][m] for q in qids])
        lo, hi = boot_ci(d, rng)
        return {"a": a, "b": b, "metric": m, "mean_diff": float(d.mean()), "ci95": [lo, hi],
                "queries_better": int((d > 0).sum()), "queries_worse": int((d < 0).sum())}

    comparisons = []
    pairs = []
    for emb in ("bge-base", "bge-large"):
        if emb in per_cfg:
            pairs.append((emb, "bge-small"))
    for rr in RERANKERS:
        for k in KS:
            cfg = f"bge-small+{rr}@{k}"
            if cfg in per_cfg:
                pairs.append((cfg, "bge-small"))
                for emb in ("bge-base", "bge-large"):
                    if emb in per_cfg:
                        pairs.append((cfg, emb))
    for emb in ("bge-base", "bge-large"):
        for k in KS:
            cfg = f"{emb}+minilm-l6@{k}"
            if cfg in per_cfg:
                pairs.append((cfg, emb))
                pairs.append((cfg, f"bge-small+minilm-l6@{k}"))
    for k_a, k_b in ((20, 10), (50, 20)):
        for rr in RERANKERS:
            a, b = f"bge-small+{rr}@{k_a}", f"bge-small+{rr}@{k_b}"
            if a in per_cfg and b in per_cfg:
                pairs.append((a, b))
    for a, b in pairs:
        for m in ("recall@3", "mrr@10", "ndcg@10"):
            comparisons.append(diff(a, b, m))

    # Where was the first relevant doc before and after reranking? (bge-small, MiniLM-L6)
    transitions = {}
    for k in KS:
        cfg = f"bge-small+minilm-l6@{k}"
        if cfg not in per_cfg:
            continue
        buckets: dict[str, int] = defaultdict(int)
        for q in qids:
            before = per_cfg["bge-small"][q]["first_rel_rank"]
            after = per_cfg[cfg][q]["first_rel_rank"]
            b_bucket = "1-3" if before <= 3 else ("4-%d" % k if before <= k else "beyond k")
            if np.isnan(before):
                b_bucket = "beyond k"
            a_top3 = (not np.isnan(after)) and after <= 3
            buckets[f"{b_bucket} -> {'top3' if a_top3 else 'not top3'}"] += 1
        transitions[str(k)] = dict(sorted(buckets.items()))

    first_rank_dist = {}
    fr = np.array([per_cfg["bge-small"][q]["first_rel_rank"] for q in qids])
    for lo, hi in ((1, 3), (4, 10), (11, 20), (21, 50), (51, 100)):
        first_rank_dist[f"{lo}-{hi}"] = int(((fr >= lo) & (fr <= hi)).sum())
    first_rank_dist["not in top 100"] = int(np.isnan(fr).sum())

    with gzip.open(QDIR / f"per_query.{ds_name}.jsonl.gz", "wt") as f:
        for cfg, pq in per_cfg.items():
            for q in qids:
                f.write(json.dumps({"config": cfg, "qid": q, **{m: pq[q][m] for m in METRICS + ["first_rel_rank"]}}) + "\n")

    return {"queries": len(qids), "docs": len(ds.doc_ids), "table": table, "comparisons": comparisons,
            "transitions_bge_small_minilm_l6": transitions, "bge_small_first_relevant_rank": first_rank_dist}


def latency() -> dict:
    out = {}
    for p in sorted((RESULTS / "latency").glob("*.jsonl")):
        if p.name == "runs.jsonl":
            continue
        by: dict[str, dict[int, list[dict]]] = defaultdict(lambda: defaultdict(list))
        for line in open(p):
            r = json.loads(line)
            by[r["config"]][r["run"]].append(r)
        ds_out = {}
        for cfg, runs in by.items():
            p50s = [float(np.percentile([r["total_ms"] for r in rs], 50)) for rs in runs.values()]
            p99s = [float(np.percentile([r["total_ms"] for r in rs], 99)) for rs in runs.values()]
            pooled = [r for rs in runs.values() for r in rs]
            ds_out[cfg] = {
                "runs": len(runs),
                "queries_per_run": len(next(iter(runs.values()))),
                "p50_median": float(np.median(p50s)), "p50_min": min(p50s), "p50_max": max(p50s),
                "p99_median": float(np.median(p99s)), "p99_min": min(p99s), "p99_max": max(p99s),
                "pooled_p50": float(np.percentile([r["total_ms"] for r in pooled], 50)),
                "pooled_p99": float(np.percentile([r["total_ms"] for r in pooled], 99)),
                "embed_p50": float(np.percentile([r["embed_ms"] for r in pooled], 50)),
                "search_p50": float(np.percentile([r["search_ms"] for r in pooled], 50)),
                "rerank_p50": float(np.percentile([r["rerank_ms"] for r in pooled], 50)),
                "rerank_p99": float(np.percentile([r["rerank_ms"] for r in pooled], 99)),
            }
        out[p.stem] = ds_out
    return out


def fmt_md(summary: dict) -> str:
    lines = ["# Summary (generated by scripts/analyze.py)", ""]
    for ds_name, q in summary["quality"].items():
        lines += [f"## {ds_name}: {q['queries']} test queries, {q['docs']} docs", ""]
        lines += ["| config | recall@3 | recall@10 | hit@3 | MRR@10 | nDCG@10 | retriever recall@20 |", "|---|---|---|---|---|---|---|"]
        for cfg, t in q["table"].items():
            lines.append(f"| {cfg} | {t['recall@3']:.3f} | {t['recall@10']:.3f} | {t['hit@3']:.3f} | {t['mrr@10']:.3f} | {t['ndcg@10']:.3f} | {t['retriever_recall@20']:.3f} |")
        lines += ["", "Paired bootstrap, 95% CI of the mean difference (a minus b):", "",
                  "| a | b | metric | diff | 95% CI | queries better / worse |", "|---|---|---|---|---|---|"]
        for c in q["comparisons"]:
            lines.append(f"| {c['a']} | {c['b']} | {c['metric']} | {c['mean_diff']:+.3f} | [{c['ci95'][0]:+.3f}, {c['ci95'][1]:+.3f}] | {c['queries_better']} / {c['queries_worse']} |")
        lines += ["", "bge-small: rank of the first relevant doc: " + json.dumps(q["bge_small_first_relevant_rank"]), ""]
        lines += ["bge-small + MiniLM-L6 transitions (first relevant doc before -> after): " + json.dumps(q["transitions_bge_small_minilm_l6"]), ""]
    lines += ["## Latency (ms, total per query: embed + search + rerank)", ""]
    for ds_name, cfgs in summary["latency"].items():
        lines += [f"### {ds_name}", "", "| config | runs x queries | p50 median (min-max) | p99 median (min-max) | pooled p99 | embed p50 | search p50 | rerank p50 |", "|---|---|---|---|---|---|---|---|"]
        for cfg in sorted(cfgs, key=lambda c: cfgs[c]["p50_median"]):
            l = cfgs[cfg]
            lines.append(f"| {cfg} | {l['runs']} x {l['queries_per_run']} | {l['p50_median']:.1f} ({l['p50_min']:.1f}-{l['p50_max']:.1f}) | {l['p99_median']:.1f} ({l['p99_min']:.1f}-{l['p99_max']:.1f}) | {l['pooled_p99']:.1f} | {l['embed_p50']:.1f} | {l['search_p50']:.2f} | {l['rerank_p50']:.1f} |")
        lines.append("")
    lines += ["## Index time (encode the whole corpus)", "", "| dataset | model | docs | seconds | docs/s |", "|---|---|---|---|---|"]
    for r in summary["index_time"]:
        lines.append(f"| {r['dataset']} | {r['model']} | {r['docs']} | {r['seconds']} | {r['docs_per_s']} |")
    return "\n".join(lines) + "\n"


def main() -> None:
    rng = np.random.default_rng(0)
    summary = {"quality": {}, "latency": latency(), "index_time": []}
    for ds_name in DATASETS:
        if (QDIR / "candidates" / f"{ds_name}.bge-small.jsonl.gz").exists():
            summary["quality"][ds_name] = quality(ds_name, rng)
    if (RESULTS / "index_time.jsonl").exists():
        summary["index_time"] = [json.loads(l) for l in open(RESULTS / "index_time.jsonl")]
    (RESULTS / "summary.json").write_text(json.dumps(summary, indent=1))
    (RESULTS / "summary.md").write_text(fmt_md(summary))
    print(fmt_md(summary))


if __name__ == "__main__":
    main()
