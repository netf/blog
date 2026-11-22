#!/usr/bin/env python3
"""Summarises results/ into results/summary.md (run from the lab dir after the runs)."""
import base64, collections, glob, json, os, re
from datetime import datetime

R = "results"


def ts(s):
    return datetime.fromisoformat(s[:23] + "+00:00")


def jl(path):
    return [json.loads(l) for l in open(path) if l.strip()] if os.path.exists(path) else []


def matrix():
    jobs = [j for j in jl(f"{R}/matrix/jobs.jsonl") if "duration_min" in j]
    by = {(j["arm"], j["engine"], j["duration_min"]): j for j in jobs}
    lines = ["## Matrix: job outcome by arm, engine and duration", "",
             "| engine | duration | A (static key) | B (vended, defaults, TTL 3600) | C (lakegate, TTL 900) |", "|---|---|---|---|---|"]
    for e in ["spark", "trino", "pyiceberg", "duckdb"]:
        for d in [5, 30, 61, 120]:
            cells = []
            for arm in "abc":
                j = by.get((arm, e, d))
                if d == 120:
                    cells.append("discarded (VM pause, results/incidents.md)")
                elif not j:
                    cells.append("not run")
                elif j["ok"]:
                    cells.append(f"ok {j['elapsed_s'] / 60:.1f} min")
                else:
                    cells.append(f"**FAIL at {j['elapsed_s'] / 60:.1f} min**")
            lines.append(f"| {e} | {d} | " + " | ".join(cells) + " |")
    lines += ["", "Added job time, C vs A (successful pairs):", ""]
    for e in ["spark", "trino", "pyiceberg", "duckdb"]:
        for d in [5, 30, 61, 120]:
            a, c = by.get(("a", e, d)), by.get(("c", e, d))
            if d != 120 and a and c and a["ok"] and c["ok"]:
                lines.append(f"- {e} {d} min: A {a['elapsed_s']:.1f}s, C {c['elapsed_s']:.1f}s, "
                             f"{(c['elapsed_s'] - a['elapsed_s']) / a['elapsed_s'] * 100:+.2f}%")
    lines += ["", "Errors (first 300 chars):", ""]
    for j in jobs:
        if not j["ok"] and j["duration_min"] != 120:
            lines.append(f"- {j['job']}: `{j['error'][:300]}`")
    return lines, by


def access_counts():
    """Catalog calls per job from the Polaris access logs (job tables have unique names)."""
    lines = ["", "## Catalog calls per job (Polaris access log, matrix window)", "",
             "| arm | engine | duration | loadTable | /credentials | commits |", "|---|---|---|---|---|---|"]
    pat = re.compile(r'"(GET|POST|HEAD) /api/catalog/v1/(lake_[abc])/(namespaces/ops/tables/(\w+)(/credentials)?|transactions/commit)')
    counts = collections.Counter()
    tx = collections.Counter()
    for f in glob.glob(f"{R}/matrix/access-polaris-*.log"):
        for l in open(f, errors="replace"):
            m = pat.search(l)
            if not m:
                continue
            method, cat, _, table, cred = m.groups()
            if table is None:
                tx[cat] += 1
                continue
            kind = "cred" if cred else ("load" if method == "GET" else ("commit" if method == "POST" else "head"))
            counts[(cat, table, kind)] += 1
    for arm in "abc":
        for e in ["spark", "trino", "pyiceberg", "duckdb"]:
            for d in [5, 30, 61, 120]:
                cat = f"lake_{arm}"
                src, tgt = f"src_{e}_{d}", f"tgt_{e}_{d}"
                load = counts[(cat, src, "load")] + counts[(cat, tgt, "load")]
                cred = counts[(cat, src, "cred")] + counts[(cat, tgt, "cred")]
                com = counts[(cat, tgt, "commit")]
                lines.append(f"| {arm} | {e} | {d} | {load} | {cred} | {com} |")
    lines.append("")
    lines.append(f"POST /transactions/commit per catalog (DuckDB's commit path): {dict(tx)}")
    return lines


def policy_of(r):
    """AssumeRole audit entries carry the session policy base64-encoded only."""
    c = r.get("requestClaims", {})
    if c.get("sessionPolicy-extracted"):
        return c["sessionPolicy-extracted"]
    try:
        return base64.b64decode(c.get("sessionPolicy", "")).decode()
    except ValueError:
        return ""


def sts_calls(run="matrix"):
    s = open(f"{R}/{run}/started.txt").read().strip()
    e = open(f"{R}/{run}/finished.txt").read().strip() if os.path.exists(f"{R}/{run}/finished.txt") else "9999"
    c = collections.Counter()
    for l in open(f"{R}/audit/audit.jsonl"):
        if '"AssumeRole"' not in l:
            continue
        r = json.loads(l)
        if not (s[:19] <= r["time"][:19] <= e[:19]):
            continue
        pol = policy_of(r)
        cat = re.search(r"arn:aws:s3:::lake/(lake_\w|lk)", pol)
        c[cat.group(1) if cat else "?"] += 1
    return ["", f"## STS AssumeRole calls during the {run} window, by catalog in the session policy", "", str(dict(c))]


def cpu():
    rows = collections.defaultdict(list)
    path = f"{R}/matrix/docker-stats.tsv"
    if not os.path.exists(path):
        return []
    for l in open(path):
        p = l.rstrip("\n").split("\t")
        if len(p) >= 3 and p[1].startswith("lakegate-polaris"):
            rows[p[1]].append(float(p[2].rstrip("%")))
    out = ["", "## Catalog CPU during the matrix (docker stats every 30 s, % of one core)", ""]
    for k, v in sorted(rows.items()):
        out.append(f"- {k}: mean {sum(v) / len(v):.2f}%, max {max(v):.2f}%, samples {len(v)}")
    return out


def failures():
    out = ["", "## Failure tests (results/failure)", "", "| job | ok | elapsed | error |", "|---|---|---|---|"]
    for j in jl(f"{R}/failure/jobs.jsonl"):
        note = " (discarded: VM pause, results/incidents.md)" if "-f1b" in j["job"] else ""
        out.append(f"| {j['job']}{note} | {j['ok']} | {j['elapsed_s'] / 60:.1f} min | {j.get('error', '')[:220]} |")
    out += ["", "Events:", "", "```"] + [l.rstrip() for l in open(f"{R}/failure/events.log")] + ["```"]
    return out


def load():
    out = ["", "## Load test (Polaris C, 50 workers)", ""]
    for f in sorted(glob.glob(f"{R}/load/*-*.json")):
        d = json.load(open(f))
        out.append(f"- {d['mode']} {d['shape']}: loadTable {d.get('loadTable')}, credentials {d.get('credentials')}, "
                   f"errors {d['errors']}, STS calls {d.get('sts_assume_role_calls')}, CPU max {d.get('polaris_cpu_pct_max')}%")
    return out


if __name__ == "__main__":
    lines, _ = matrix()
    lines += access_counts() + ["", "Counts above include the lab's own scans (blast radius, cut-over check) that ran inside the",
             "matrix window; clean per-job counts are in results/matrix-120/catalog-calls-first-53min.txt:", "", "```"]
    lines += [l.rstrip() for l in open(f"{R}/matrix-120/catalog-calls-first-53min.txt")] + ["```"]
    lines += sts_calls() + cpu() + failures() + load()
    open(f"{R}/summary.md", "w").write("# lakegate results summary (generated by scripts/60-analyze.py)\n\n" + "\n".join(lines) + "\n")
    print("\n".join(lines))
