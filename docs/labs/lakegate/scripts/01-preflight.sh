#!/usr/bin/env bash
# Prints the raw environment facts recorded in environment.md.
set -uo pipefail
section() { printf '\n## %s\n' "$1"; }
section compute; nproc; free -h; df -h / "$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /)"
systemd-detect-virt 2>&1; cat /proc/cmdline; head -2 /etc/os-release; echo "PID1: $(ps -p 1 -o comm=)"
ps -eo rss= | awk '{s+=$1} END {printf "process RSS total: %.0f MiB\n", s/1024}'; grep balloon /proc/vmstat
section kernel; uname -r; stat -fc %T /sys/fs/cgroup; cat /sys/fs/cgroup/cgroup.controllers
iptables -V; sudo iptables-legacy -S FORWARD | head -3; nft --version
ls /lib/modules 2>&1 | head -1; echo "net.bridge.bridge-nf-call-iptables=$(sysctl -n net.bridge.bridge-nf-call-iptables)"
section container-tooling
docker version --format 'docker client {{.Client.Version}} server {{.Server.Version}}'
docker info --format 'storage={{.Driver}} cgroupdriver={{.CgroupDriver}} cgroup=v{{.CgroupVersion}} root={{.DockerRootDir}} security={{.SecurityOptions}}'
docker compose version; command -v kind || echo "kind: not installed (not used)"
section tools; java -version 2>&1 | head -1
/tmp/lgvenv/bin/python -c "import pyiceberg,duckdb,pyarrow;print('pyiceberg',pyiceberg.__version__,'duckdb',duckdb.__version__,'pyarrow',pyarrow.__version__)"
/tmp/lgvenv/bin/python -c "import duckdb;c=duckdb.connect();c.execute('LOAD iceberg');print(c.execute(\"select extension_name,extension_version from duckdb_extensions() where extension_name in ('iceberg','httpfs','avro')\").fetchall())"
docker run --rm --entrypoint /opt/spark/bin/spark-submit apache/spark:4.3.0 --version 2>&1 | grep -E 'version|Scala' | head -2
docker run --rm --entrypoint trino trinodb/trino:484 --version
docker run --rm --entrypoint minio cgr.dev/chainguard/minio:latest --version | head -1
docker run --rm cgr.dev/chainguard/minio-client:latest --version | head -1
for i in apache/polaris:1.9.0 quay.io/lakekeeper/catalog:v0.15.1 apache/spark:4.3.0 trinodb/trino:484 cgr.dev/chainguard/minio:latest postgres:17; do
  echo "$i $(docker image inspect -f '{{index .RepoDigests 0}}' $i 2>/dev/null)"; done
section upstream-minio
for i in minio/minio:latest minio/minio:RELEASE.2025-09-07T16-13-09Z quay.io/minio/minio:latest quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z minio/mc:latest; do
  printf '%s: ' "$i"; docker manifest inspect "$i" >/dev/null 2>&1 && echo present || echo "not pullable"; done
gh repo view minio/minio --json isArchived,pushedAt 2>&1
section iceberg-spark-runtimes
curl -fsS https://repo1.maven.org/maven2/org/apache/iceberg/ | grep -o 'iceberg-spark-runtime-[0-9.]*_2.13' | sort -u
curl -fsS https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-4.1_2.13/maven-metadata.xml | grep -o '<latest>[^<]*'
section network
for u in https://registry-1.docker.io/v2/ https://quay.io/v2/ https://cgr.dev/v2/ https://repo1.maven.org/maven2/ https://pypi.org/simple/ https://extensions.duckdb.org/; do
  printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$u")" "$u"; done
sudo ip netns add lgpf && sudo ip netns exec lgpf tc qdisc add dev lo clsact && echo "netns + tc clsact: ok"; sudo ip netns del lgpf
section clock-and-limits; echo "ulimit -n $(ulimit -n)"; ls /etc/chrony* /etc/systemd/timesyncd.conf 2>&1 | head -2
python3 - <<'E'
import socket,struct,time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(3)
s.sendto(b'\x1b'+47*b'\0',('time.google.com',123));d=s.recv(48)
print('SNTP offset vs time.google.com (s, 1 s resolution):', round(struct.unpack('!I',d[40:44])[0]-2208988800-time.time(),1))
E
