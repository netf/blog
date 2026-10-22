"""Turn raw results into the tables quoted in the post.  summarize.py > results/summary.md"""
import glob
import json
import pathlib
import statistics as st

R = pathlib.Path(__file__).resolve().parent.parent / "results"
MODES = ["plain", "sha256", "daead"]
LABEL = {"plain": "plaintext", "sha256": "salted SHA-256", "daead": "AES-SIV (Tink)"}


def jl(path):
    return [json.loads(l) for l in open(path) if l.strip()]


def spread(xs, fmt="{:,.0f}"):
    return f"{fmt.format(st.median(xs))} ({fmt.format(min(xs))}–{fmt.format(max(xs))})"


def ingest():
    runs = jl(R / "ingest" / "runs.jsonl")
    print("## Ingest (median, min–max across runs)\n")
    print(f"runs per cell: {len({r['round'] for r in runs})}\n")
    print("| variant | table | rows/s | CPU s per 1M rows | transform s | Postgres backend CPU s | peak RSS MB |")
    print("|---|---|---|---|---|---|---|")
    for t in ("customers", "orders"):
        for m in MODES:
            rs = [r for r in runs if r["mode"] == m and r["table"] == t]
            print(f"| {LABEL[m]} | {t} | {spread([r['rows_per_s'] for r in rs])} | "
                  f"{spread([r['cpu_s_per_mrow'] for r in rs], '{:.2f}')} | {spread([r['transform_s'] for r in rs], '{:.1f}')} | "
                  f"{spread([r['pg_cpu_s'] for r in rs], '{:.1f}')} | {max(r['peak_rss_mb'] for r in rs)} |")
    print()
    both = {}
    for m in MODES:
        rs = [r for r in runs if r["mode"] == m]
        rounds = sorted({r["round"] for r in rs})
        per_round = [sum(r["cpu_s"] for r in rs if r["round"] == k) / sum(r["rows"] for r in rs if r["round"] == k) * 1e6 for k in rounds]
        rps = [sum(r["rows"] for r in rs if r["round"] == k) / sum(r["wall_s"] for r in rs if r["round"] == k) for k in rounds]
        both[m] = (per_round, rps)
        print(f"- {LABEL[m]}, both tables (60M rows): {spread(rps)} rows/s, {spread(per_round, '{:.3f}')} CPU s per 1M rows")
    base = st.median(both["plain"][0])
    for m in ("sha256", "daead"):
        print(f"- {LABEL[m]} extra CPU over plaintext: {st.median(both[m][0]) - base:.3f} s per 1M rows")
    print()


def sizes():
    p = R / "sizes" / "sizes.json"
    if not p.exists():
        return
    d = json.load(open(p))
    print("## Parquet size (zstd level 3)\n")
    print("| file | plaintext | salted SHA-256 | AES-SIV |")
    print("|---|---|---|---|")
    for t in ("customers", "orders"):
        print(f"| {t}.parquet | " + " | ".join(f"{d['files'][f'{m}/{t}']['file_bytes'] / 1e6:,.0f} MB" for m in MODES) + " |")
    print("\n| column | variant | stored MB | logical MB | ratio | encodings |")
    print("|---|---|---|---|---|---|")
    for t, cols in (("customers", ["email", "phone", "country"]), ("orders", ["customer_email", "amount_pence"])):
        for c in cols:
            for m in MODES:
                x = d["files"][f"{m}/{t}"]["columns"][c]
                print(f"| {t}.{c} | {LABEL[m]} | {x['stored_bytes'] / 1e6:,.1f} | {x['logical_bytes'] / 1e6:,.1f} | {x['ratio']} | {', '.join(x['encodings'])} |")
    print(f"\nCodec check on the first {d['codecs']['sample_rows']:,} rows of each PII column (bytes):\n")
    print("| column / variant | none | snappy | zstd3 | zstd9 |")
    print("|---|---|---|---|---|")
    keys = sorted({k.rsplit('/', 1)[0] for k in d["codecs"] if "/" in k})
    for k in keys:
        print(f"| {k} | " + " | ".join(f"{d['codecs'][f'{k}/{c}'] / 1e6:,.1f} MB" for c in ("none", "snappy", "zstd3", "zstd9")) + " |")
    print()


def joins():
    p = R / "join" / "runs.jsonl"
    if not p.exists():
        return
    rs = jl(p)
    data = [r for r in rs if "mode" in r]
    check = [r for r in rs if r.get("check")]
    print("## DuckDB query latency, ms (median of all timed reps, min–max of per-round medians)\n")
    print("| source | query | plaintext | salted SHA-256 | AES-SIV |")
    print("|---|---|---|---|---|")
    for src in ("table", "parquet"):
        for q in ("join_agg", "distinct", "point"):
            cells = []
            for m in MODES:
                sel = [r for r in data if r["mode"] == m and r["source"] == src and r["query"] == q]
                allms = [x for r in sel for x in r["ms"]]
                rmeds = [st.median(r["ms"]) for r in sel]
                cells.append(f"{st.median(allms):,.1f} ({min(rmeds):,.1f}–{max(rmeds):,.1f})")
            print(f"| {src} | {q} | " + " | ".join(cells) + " |")
    if check:
        print(f"\nidentical results across variants: {check[0]['ok']}")
    print()


def rotation():
    files = sorted(glob.glob(str(R / "rotation" / "*.json")))
    if not files:
        return
    rs = [json.load(open(f)) for f in files]
    print("## Key rotation (single process)\n")
    print("| column | run | rows rewritten | wall s | CPU s | CPU s per 1M rows | lazy-rotation matches | after rewrite | old-key tokens left |")
    print("|---|---|---|---|---|---|---|---|---|")
    for r in rs:
        lz = r.get("lazy_rotation_matches")
        print(f"| {r['column']} | {r['run']} | {r['rows']:,} | {r['wall_s']} | {r['cpu_s']} | {r['cpu_s_per_mrow']} | "
              f"{lz['matched'] if lz else '-'} / {lz['sampled'] if lz else '-'} | {r.get('after_rewrite_matches', '-')} | "
              f"{sum(f['old_key_tokens_left'] for f in r['files'])} |")
    print()


if __name__ == "__main__":
    ingest()
    sizes()
    joins()
    rotation()
