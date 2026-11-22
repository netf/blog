#!/usr/bin/env bash
# Brings the planned stack up once, puts light load on the JVM services, and records the
# peak container memory (docker stats) plus host-side used memory every 2 s.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=results/preflight/memory-bringup.txt
F=preflight/compose.memory.yaml
docker compose -f $F up -d --wait-timeout 300 2>&1 | tail -3
: > /tmp/lg-stats.tsv
sample() { docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' >> /tmp/lg-stats.tsv; }
for i in $(seq 1 10); do sample; sleep 2; done
until curl -fs localhost:8080/v1/info | grep -q '"starting":false'; do sleep 2; done
docker compose -f $F exec -T trino trino --execute "select count(*) from tpch.sf1.lineitem" > /tmp/lg-trino.txt 2>&1 &
docker compose -f $F exec -T spark /opt/spark/bin/spark-submit --master 'local[4]' --driver-memory 2g \
  --class org.apache.spark.examples.SparkPi /opt/spark/examples/jars/spark-examples_2.13-4.3.0.jar 2000 > /tmp/lg-spark.txt 2>&1 &
for i in $(seq 1 30); do sample; sleep 2; done
wait
{
  echo "# docker stats peak per container (MiB) during idle + tpch sf1 count on Trino + SparkPi(2000) local[4] driver 2g"
  python3 - <<'E'
import re,collections
peak=collections.defaultdict(float)
for line in open('/tmp/lg-stats.tsv'):
    name,use=line.rstrip('\n').split('\t'); v=use.split('/')[0].strip()
    m=re.match(r'([\d.]+)([KMG]i?B)',v); n=float(m.group(1)); u=m.group(2)
    n*= {'KiB':1/1024,'MiB':1,'GiB':1024,'B':1/1048576}.get(u,1)
    peak[name]=max(peak[name],n)
for k,v in sorted(peak.items()): print(f"{k:40s} {v:8.0f}")
print(f"{'sum of per-container peaks':40s} {sum(peak.values()):8.0f}")
E
  echo; echo "# trino:"; tail -2 /tmp/lg-trino.txt; echo "# spark:"; grep -E "Pi is" /tmp/lg-spark.txt
  echo; echo "# host after load"; free -m; grep balloon /proc/vmstat
} | tee $OUT
docker compose -f $F down -v >/dev/null 2>&1
