#!/usr/bin/env python3
"""Turn results/bench/*.jsonl into the Markdown tables used in the post.

Latency: median across rounds of each percentile, with min-max in brackets.
CPU: data-plane cores = sum of sidecars, or ztunnels (+ waypoint); also shown
as millicores per 1000 requests/s so runs at different rates are comparable.
"""
import json
import statistics as st
import sys
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent
MODES = ["baseline", "sidecar", "ambient", "ambient-wp"]


def load(name):
    p = LAB / "results" / "bench" / f"{name}.jsonl"
    rows = [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
    return {m: [r for r in rows if r["mode"] == m] for m in MODES}


def med(xs):
    return st.median(xs)


def fmt(xs, nd=2):
    return f"{med(xs):.{nd}f} ({min(xs):.{nd}f}-{max(xs):.{nd}f})"


def errors(r):
    return sum(v for k, v in r["codes"].items() if k != "200")


def latency_table(name):
    d = load(name)
    out = [f"### {name}: latency in ms, median of {len(d['baseline'])} rounds (min-max)", "",
           "| mode | achieved rps | p50 | p90 | p99 | p99.9 | non-200 |",
           "|---|---|---|---|---|---|---|"]
    for m in MODES:
        rs = d[m]
        out.append("| {} | {} | {} | {} | {} | {} | {} |".format(
            m, fmt([r["qps"] for r in rs], 0), fmt([r["p50_ms"] for r in rs]), fmt([r["p90_ms"] for r in rs]),
            fmt([r["p99_ms"] for r in rs]), fmt([r["p999_ms"] for r in rs]), sum(errors(r) for r in rs)))
    return "\n".join(out)


def cpu_table(name):
    d = load(name)
    out = [f"### {name}: CPU in cores during the run, median of rounds", "",
           "| mode | data-plane cores | breakdown | dp millicores per 1k rps | app (client+server) cores | both worker nodes, total cores |",
           "|---|---|---|---|---|---|"]
    for m in MODES:
        rs = d[m]
        dp = [sum(v for k, v in r["cpu_cores"].items() if k.startswith("dp:")) for r in rs]
        app = [sum(v for k, v in r["cpu_cores"].items() if k.startswith("app:")) for r in rs]
        node = [sum(v for k, v in r["cpu_cores"].items() if k.startswith("node:")) for r in rs]
        per1k = [x * 1000 / (r["qps"] / 1000) for x, r in zip(dp, rs)]
        keys = sorted({k for r in rs for k in r["cpu_cores"] if k.startswith("dp:")})
        brk = ", ".join(f"{k[3:]} {med([r['cpu_cores'].get(k, 0) for r in rs]):.3f}" for k in keys) or "-"
        out.append(f"| {m} | {med(dp):.3f} | {brk} | {med(per1k):.0f} | {med(app):.3f} | {med(node):.3f} |")
    return "\n".join(out)


def mem_table(name):
    d = load(name)
    out = [f"### {name}: data-plane working set at end of run (MiB), median of rounds", "",
           "| mode | containers |", "|---|---|"]
    for m in MODES:
        rs = d[m]
        keys = sorted({k for r in rs for k in r["mem_bytes"] if k.startswith("dp:")})
        out.append(f"| {m} | " + (", ".join(
            f"{k[3:]} {med([r['mem_bytes'].get(k, 0) for r in rs]) / 2**20:.1f}" for k in keys) or "-") + " |")
    return "\n".join(out)


if __name__ == "__main__":
    for name in sys.argv[1:] or ["fixed", "max", "noka"]:
        if (LAB / "results" / "bench" / f"{name}.jsonl").exists():
            print(latency_table(name), "\n")
            print(cpu_table(name), "\n")
            print(mem_table(name), "\n")
