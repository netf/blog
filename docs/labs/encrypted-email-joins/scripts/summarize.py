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


def attacks():
    dic = [json.load(open(f)) for f in sorted(glob.glob(str(R / "attack" / "dictionary-run*.json")))]
    ph = [json.load(open(f)) for f in sorted(glob.glob(str(R / "attack" / "phone-run*.json")))]
    if dic:
        print("## Dictionary attack on email (10M candidates)\n")
        print("| run | upper bound | sha256, salt known | sha256, no salt | AES-SIV, no key | AES-SIV, pipeline key | hash s | encrypt s |")
        print("|---|---|---|---|---|---|---|---|")
        for i, d in enumerate(dic, 1):
            print(f"| {i} | {d['upper_bound']['rows']:,} | {d['sha256_salt_known']['recovered_rows']:,} | {d['sha256_salt_unknown']['recovered_rows']} | "
                  f"{d['daead_no_key']['recovered_rows']} | {d['daead_pipeline_key']['recovered_rows']:,} | {d['sha256_salt_known']['hash_s']} | {d['daead_pipeline_key']['encrypt_s']} |")
        print()
    if ph:
        print("## Phone enumeration (1e9 candidates)\n")
        print("| run | sha256 recovered | s | AES-SIV recovered | s |")
        print("|---|---|---|---|---|")
        for p in ph:
            print(f"| {p['run']} | {p['sha256']['recovered']:,} | {p['sha256']['seconds']} | {p['daead']['recovered']:,} | {p['daead']['seconds']} |")
        print()


def security():
    f = R / "frequency" / "frequency.json"
    if f.exists():
        d = json.load(open(f))
        print("## Frequency analysis on tokenized country\n")
        for r in d["runs"]:
            print(f"- prior seed {r['seed']}: {r['rows_labelled_correctly_pct']}% rows, {r['countries_identified']}/30 countries, top-5 {r['top5_correct']}/5")
        print(f"- most frequent token alone: {d['only_knowing_gb_is_biggest']['is']} = {d['only_knowing_gb_is_biggest']['rows_pct']}% of rows")
        print(f"- randomized AEAD control: {d['control_randomized_aead']['distinct_tokens']:,} distinct tokens for {d['control_randomized_aead']['rows']:,} rows\n")
    f = R / "reid" / "reid.json"
    if f.exists():
        d = json.load(open(f))
        print("## Re-identification service\n")
        print("matrix: " + ", ".join(f"{k}={v}" for k, v in d["matrix"].items()))
        print(f"\nround trip ok: {d['round_trip_100']['all_match_plaintext']}, tokenize matches warehouse: {d['tokenize_matches_warehouse_100']}, "
              f"phone token as email: {d['phone_token_sent_as_email']}, unknown caller: {d['unknown_caller']}, over cap: {d['support_over_per_request_cap']}, "
              f"budget: {d['support_budget_20x4_within_a_minute']}, audit records: {d['audit']['records']}, plaintext in audit: {d['audit']['plaintext_emails_found_in_log']}")
        print("latency: " + "; ".join(f"p50 {x['p50_ms']} ms p99 {x['p99_ms']} ms" for x in d["single_token_latency"]) + "\n")


def layout():
    f = R / "layout" / "sort.json"
    if f.exists():
        d = json.load(open(f))
        print("## orders.parquet sorted vs unsorted (DuckDB writer)\n")
        print("| variant | unsorted MB | sorted MB | email col unsorted MB | email col sorted MB |")
        print("|---|---|---|---|---|")
        for m in MODES:
            u, s = d[f"{m}/unsorted"], d[f"{m}/sorted"]
            print(f"| {LABEL[m]} | {u['file_bytes'] / 1e6:,.0f} | {s['file_bytes'] / 1e6:,.0f} | {u['customer_email_bytes'] / 1e6:,.0f} | {s['customer_email_bytes'] / 1e6:,.0f} |")
        print()
    f = R / "layout" / "prefix.jsonl"
    if f.exists():
        rs = [r for r in jl(f) if "variant" in r]
        print("## Tink prefix vs stripped (ms, median of round medians, min–max)\n")
        print("| query | plaintext | Tink prefix | stripped |")
        print("|---|---|---|---|")
        for q in ("join_agg", "distinct", "point"):
            cells = [spread([r["median"] for r in rs if r["variant"] == v and r["query"] == q]) for v in ("plaintext", "tinkprefix", "stripped")]
            print(f"| {q} | " + " | ".join(cells) + " |")
        print()


if __name__ == "__main__":
    ingest()
    sizes()
    joins()
    rotation()
    attacks()
    security()
    layout()
