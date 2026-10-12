#!/usr/bin/env python3
"""Latency/throughput/CPU benchmark across baseline, sidecar, ambient, ambient-wp.

For every run it:
  1. runs a short warm-up (discarded),
  2. snapshots per-container CPU counters with `crictl stats` on both workers
     (containerd reads the cgroup at request time, unlike the kubelet summary API),
  3. runs fortio inside the client pod,
  4. snapshots again and attributes the CPU delta to app / data-plane containers.

Modes are interleaved per round so slow drift on the shared VM hits all of them.

Usage: bench.py <scenario> <rounds>     scenarios: fixed | max | noka
"""
import json
import subprocess
import sys
import time
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent
OUT = LAB / "results" / "bench"
NODES = ["mesh-lab-worker", "mesh-lab-worker2"]
MODES = ["baseline", "sidecar", "ambient", "ambient-wp"]

SCENARIOS = {
    # fixed open-loop-ish rate over keep-alive connections
    "fixed": ["-qps", "1000", "-c", "16", "-t", "60s"],
    # closed loop, as fast as possible
    "max": ["-qps", "0", "-c", "16", "-t", "30s"],
    # a new TCP connection for every request
    "smoke": ["-qps", "200", "-c", "4", "-t", "10s"],
    "noka": ["-qps", "200", "-c", "4", "-t", "30s", "-keepalive=false"],
}


def sh(cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def snapshot():
    rows = []
    for node in NODES:
        stats = json.loads(sh(["docker", "exec", node, "crictl", "stats", "-o", "json"]))
        for s in stats["stats"]:
            if "cpu" not in s:  # exited containers (istio-init) report no stats
                continue
            lab = s["attributes"]["labels"]
            rows.append({
                "node": node,
                "ns": lab.get("io.kubernetes.pod.namespace"),
                "pod": lab.get("io.kubernetes.pod.name"),
                "container": lab.get("io.kubernetes.container.name"),
                "cpu_ns": int(s["cpu"]["usageCoreNanoSeconds"]["value"]),
                "mem": int(s["memory"]["workingSetBytes"]["value"]),
            })
        node_cpu = sh(["docker", "exec", node, "cat", "/sys/fs/cgroup/cpu.stat"])
        usage = int(next(l.split()[1] for l in node_cpu.splitlines() if l.startswith("usage_usec")))
        rows.append({"node": node, "ns": "_node", "pod": node, "container": "_node",
                     "cpu_ns": usage * 1000, "mem": 0})
    return rows


def role(mode, r):
    """Classify a container for a given mode, or None if irrelevant."""
    if r["ns"] == "_node":
        return "node:" + r["node"].replace("mesh-lab-", "")
    if r["ns"] == mode and r["container"] == "fortio":
        return "app:" + r["pod"].split("-")[0]
    if mode == "sidecar" and r["ns"] == "sidecar" and r["container"] == "istio-proxy":
        return "dp:sidecar-" + r["pod"].split("-")[0]
    if mode.startswith("ambient") and r["ns"] == "istio-system" and r["pod"].startswith("ztunnel"):
        return "dp:ztunnel-" + r["node"].replace("mesh-lab-", "")
    if mode == "ambient-wp" and r["ns"] == "ambient-wp" and r["pod"].startswith("waypoint"):
        return "dp:waypoint"
    return None


def fortio(mode, args, extra=()):
    cmd = ["kubectl", "-n", mode, "exec", "deploy/client", "-c", "fortio", "--",
           "fortio", "load", *args, "-r", "0.00001", "-p", "50,90,99,99.9",
           "-json", "-", *extra, "http://server:8080/echo"]
    return json.loads(sh(cmd))


def run(scenario, rnd, mode):
    args = SCENARIOS[scenario]
    warm = [a if a != args[args.index("-t") + 1] else "5s" for a in args]
    fortio(mode, warm)
    before = snapshot()
    t0 = time.time()
    res = fortio(mode, args)
    wall = time.time() - t0
    after = snapshot()
    key = lambda r: (r["node"], r["ns"], r["pod"], r["container"])
    b = {key(r): r for r in before}
    cpu, mem = {}, {}
    for r in after:
        k = key(r)
        if k not in b:
            continue
        ro = role(mode, r)
        if ro is None:
            continue
        cpu[ro] = cpu.get(ro, 0) + (r["cpu_ns"] - b[k]["cpu_ns"]) / 1e9 / res["ActualDuration"] * 1e9
        mem[ro] = mem.get(ro, 0) + r["mem"]
    h = res["DurationHistogram"]
    pct = {str(p["Percentile"]): p["Value"] * 1000 for p in h["Percentiles"]}
    row = {
        "scenario": scenario, "round": rnd, "mode": mode,
        "qps": res["ActualQPS"], "count": h["Count"], "codes": res["RetCodes"],
        "sockets": res["SocketCount"], "avg_ms": h["Avg"] * 1000, "max_ms": h["Max"] * 1000,
        "p50_ms": pct["50"], "p90_ms": pct["90"], "p99_ms": pct["99"], "p999_ms": pct["99.9"],
        "cpu_cores": cpu, "mem_bytes": mem, "wall_s": wall,
    }
    print(json.dumps({k: row[k] for k in ("scenario", "round", "mode", "qps", "p50_ms", "p99_ms", "codes")}), flush=True)
    return row


def main():
    scenario, rounds = sys.argv[1], int(sys.argv[2])
    OUT.mkdir(parents=True, exist_ok=True)
    with open(OUT / f"{scenario}.jsonl", "a") as f:
        for rnd in range(1, rounds + 1):
            order = MODES[rnd % len(MODES):] + MODES[:rnd % len(MODES)]
            for mode in order:
                f.write(json.dumps(run(scenario, rnd, mode)) + "\n")
                f.flush()
                time.sleep(5)


if __name__ == "__main__":
    main()
