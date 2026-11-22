# Environment preflight: lakegate

## Decisions (Piotr, 2026-11-22 10:30Z) and pins used for measurement

1. **MinIO:** Chainguard's fork-built image, not upstream MinIO (upstream stopped publishing images).
   `cgr.dev/chainguard/minio@sha256:548147b5fc95a67e3e45285dff7e0e50326c3eb1977c6218039461771156c5e7`,
   which reports `minio version RELEASE.2026-11-16T00-11-40Z (commit-id=ee9fee0715118245ff4d9149c102608653748196)`.
   Client: `cgr.dev/chainguard/minio-client:latest` (reports `DEVELOPMENT.GOGET`).
2. **Spark:** 4.1.4 (latest 4.1.x on lab day; the pitch said 4.3.0) with Iceberg 1.12.0's official
   `iceberg-spark-runtime-4.1_2.13-1.12.0.jar` (sha1 `9e395e37…`) and `iceberg-aws-bundle-1.12.0.jar`
   (sha1 `64d50122…`), both matching Maven Central's `.sha1`.
3. **Clock skew test:** dropped.

Re-pinned at 10:31Z, before the first measurement (nothing had moved since the morning preflight):

| Component | Used | Digest / build |
|---|---|---|
| Polaris | 1.9.0 | `apache/polaris@sha256:bc548500…` |
| Lakekeeper | v0.15.1 | `quay.io/lakekeeper/catalog@sha256:22dcb604…` |
| Spark | 4.1.4 (Scala 2.13.17, Java 21.0.12) | `apache/spark:4.1.4-python3@sha256:847f91f8…` + boto3 1.44.9, requests 2.34.2 (`images/spark`) |
| Iceberg Java | 1.12.0 | Spark: jars above. Trino 484 bundles `iceberg-core-1.12.0` too |
| Trino | 484 | `trinodb/trino@sha256:2704eb53…` |
| PyIceberg | 0.12.0 (`[pyarrow]`), pyarrow 26.0.1 | `images/py` on `python:3.12-slim` |
| DuckDB | 2.0.1; iceberg `f979b5b28a`, httpfs `f71cfdb4bf`, avro `4176191c96` | `images/py` |
| Other Python | boto3 1.44.9, requests 2.34.2, trino 0.340.0, numpy 2.3.5 | `images/py` |
| STS proxy | socat 1.8.1.3 | `alpine/socat@sha256:5aa280c6…` |
| Postgres (Lakekeeper) | 17 | `postgres@sha256:223efeb1…` |

Lab-side settings that are part of the experiment (all in `compose.yaml` / `config/`):
- Polaris B: defaults (`STORAGE_CREDENTIAL_DURATION_SECONDS` 3600, cache 1800). Polaris C and F:
  900 / 450. OAuth token lifetime: default `max-token-generation=PT1H`. Persistence: in-memory.
- Every Polaris catalog: `kmsUnavailable: true`, `stsEndpoint: http://sts:9000` (the proxy).
- Lakekeeper warehouse: `flavor: s3-compat`, `sts-enabled: true`, `sts-token-validity-seconds: 900`, no
  authentication (no IdP), so Lakekeeper was tested for vending, scoping and refresh, not grants.
- Trino: `task.max-drivers-per-task=1` and `task.min-drivers-per-task=1` so a job query reads its
  source files one at a time (otherwise three splits were read at once), `task.max-worker-threads=64`.
- The Polaris access-log pattern asks for `%D`, but Quarkus prints `-` without
  `quarkus.http.record-request-start-time=true`; request counts come from that log, latencies from
  client-side timing (`kit/loadtest.py`). Not changed mid-run: restarting the in-memory Polaris
  would have dropped the catalogs.

## Preflight status (morning, superseded by the decisions above): BLOCKED before the first measurement (two pinned components)

Recorded 2026-11-22. Nothing below is a measurement; no arm (A, B or C) has been run, and no post
has been written. `scripts/01-preflight.sh` prints the raw facts (`results/preflight/preflight.txt`).

### Blocker 1: MinIO is no longer distributed upstream

The pitch builds the whole lab on "MinIO with STS". On lab day:

- `minio/minio` on Docker Hub: `pull access denied ... repository does not exist`. Every tag I
  tried, including `latest`, `RELEASE.2025-09-07T16-13-09Z` and `RELEASE.2025-04-22T22-12-26Z`.
- `quay.io/minio/minio` and `quay.io/minio/mc`: `401 UNAUTHORIZED` on every tag.
- `github.com/minio/minio` is **archived** (last push 2026-04-24). The last tag is
  `RELEASE.2025-10-15T17-29-55Z` (commit `9e49d5e7`), whose commit message is "update README.md
  and other docs to point to source only releases". Later commits only edit the README
  ("maintenance mode", "free license and enterprise option").

**Why it matters:** MinIO's STS (`AssumeRole` with a session policy) is the mechanism that makes a
vended credential table-scoped, so the escape tester and every blast-radius number measure MinIO's
policy evaluation. Which MinIO build I use is part of the experiment. A reader also can't run the
reproduce command against an image that doesn't exist.

**What does work (checked):**

| Candidate | Provenance | Version it reports |
|---|---|---|
| `cgr.dev/chainguard/minio:latest` (`sha256:548147b5…`) | Chainguard's continuation. Its commit `ee9fee07` is a fork commit (PR "#58"), not on upstream `master` | `RELEASE.2026-11-16T00-11-40Z`, go1.27.4 |
| `bitnamilegacy/minio:2025.7.23` | Bitnami's frozen legacy repo | `DEVELOPMENT.2025-07-23T15-54-02Z`; predates the 2025-10-15 security release |
| Build upstream tag `RELEASE.2025-10-15T17-29-55Z` from source | upstream, frozen | not built yet |
| MinIO AIStor | commercial, licence required | not tried |

The Chainguard image passed the feasibility probe below (STS + session policy work).

**Options (Piotr to choose):**

1. **Build upstream `RELEASE.2025-10-15T17-29-55Z` from source** and pin that commit. This is
   still "MinIO" with no third party involved, and it is the final upstream release, which includes
   the October 2025 security fix. The cost: the reproduce command needs a `docker build` step, and
   readers get a frozen, unmaintained server. This is what I'd pick, because the post's claims
   would then be about MinIO itself.
2. **Use `cgr.dev/chainguard/minio` pinned by digest.** It is pullable today and maintained, but
   the post would be measuring Chainguard's fork, and the methodology has to say so.
3. **Swap the object store** for one whose STS is maintained upstream. Polaris 1.9.0's own S3
   integration tests now run against RustFS (`RestCatalogRustFSSpecialIT`), and Lakekeeper's docs
   list Ceph RGW. This changes the title ("MinIO STS") and redoes the probe below.

### Blocker 2: "Spark 4.3.0 + Iceberg 1.12.0" does not exist

- Iceberg 1.12.0 publishes Spark runtimes up to `iceberg-spark-runtime-4.1_2.13` (Maven Central).
  The 1.12.0 source tree has a `spark/v4.2` directory but no published 4.2 jar. Spark 4.3 support
  is an open PR, [apache/iceberg#18749](https://github.com/apache/iceberg/pull/18749) "Spark:
  Initial support for Spark 4.3", and is not merged.
- Running the 4.1 runtime on `apache/spark:4.3.0` fails at session start
  (`results/preflight/spark43-with-iceberg-4.1-runtime.txt`):

  ```
  java.lang.AbstractMethodError: Receiver class org.apache.spark.sql.catalyst.parser.extensions.IcebergSparkSqlExtensionsParser
  does not define or inherit an implementation of the resolved method 'abstract
  org.apache.spark.sql.catalyst.parser.SqlStatementSplitResult splitStatements(java.lang.String)'
  ```

**Why it matters:** Spark is the engine in the title ("every Spark job"). Its refresh behaviour
comes from Iceberg's Java `VendedCredentialsProvider` (iceberg-aws), not from Spark itself, so the
Spark minor version should not change the refresh result. That is my expectation, not a test.

**Options:**

1. **Spark 4.1.4** (latest 4.1 patch, `apache/spark:4.1.4` exists) **+ Iceberg 1.12.0.** This is
   a released, supported pairing with the same Iceberg client code. This is what I'd pick.
2. **Spark 4.3.0 + Iceberg built from PR #18749.** Matches the pitch's Spark version, but the
   results would be for an unreleased, unreviewed build.
3. **Spark 4.2.1 + Iceberg 1.12.0's `v4.2` sources built locally.** Unreleased artifact, and no
   advantage over option 1.

### Decision needed, not a blocker: the clock-skew failure test

All containers read the same kernel clock, so "clock skew between MinIO and catalog" can't happen
for real on one VM. Options:

1. **Simulate it.** Run Polaris under `libfaketime` with an offset (e.g. +10 min), so it mints
   `s3.session-token-expires-at-ms` against a clock MinIO doesn't share. This tests the client's
   prefetch arithmetic (Iceberg refreshes 5 min before the expiry it was told), not real NTP drift,
   and the post would have to say "simulated".
2. **Second VM** for MinIO with its clock deliberately set wrong. Real skew, more setup.
3. **Drop it** from the failure tests and say so in the methodology.

I'd pick 1, labelled as simulated. MinIO checks its own clock for STS expiry, so the
interesting question is the client's view of the catalog-reported expiry, and a faked catalog
clock reaches that.

## Confirmed on lab day: refresh support (item 7 of the brief)

**Polaris 1.9.0 + MinIO STS: works, but not out of the box.** Probe: `scripts/03-polaris-minio-probe.py`
against the Chainguard MinIO (`results/preflight/polaris-minio-probe.json`).

- Following Polaris's own "Creating a catalog on MinIO" page (endpoint + region only), the first
  `createTable` fails:
  `StsException: invalid resource 'arn:aws:kms:us-east-1:000000000000:key/*' (Service: Sts, Status Code: 400)`.
  Polaris adds a `kms:*` statement to the session policy, and MinIO's STS rejects the ARN. Setting
  `"kmsUnavailable": true` on the catalog's storage config (CLI `--no-kms`) fixes it. The MinIO page
  doesn't mention this.
- Setting `STORAGE_CREDENTIAL_DURATION_SECONDS=900` alone breaks table creation:
  `STORAGE_CREDENTIAL_CACHE_DURATION_SECONDS should be less than STORAGE_CREDENTIAL_DURATION_SECONDS`
  (the cache default is 1800 s). Polaris defaults are TTL 3600 s, cache 1800 s.
- With both fixes, `loadTable` returns a session key scoped to `s3://lake/wh/d1/a`, with
  `s3.session-token-expires-at-ms` 899 s ahead and `client.refresh-credentials-endpoint =
  v1/lake/namespaces/d1/tables/a/credentials`. `GET .../credentials` answers 200. With that key:
  listing its own prefix was allowed, while listing table `d2.b`'s prefix, listing the bucket root,
  reading a `d2.b` data file and writing `elsewhere/x` were all `AccessDenied`.
- `createTable` with write delegation also needs `TABLE_WRITE_DATA`; `catalog_admin`'s
  `CATALOG_MANAGE_CONTENT` alone gets `not authorized for op CREATE_TABLE_DIRECT_WITH_WRITE_DELEGATION`.

**Lakekeeper v0.15.1 + MinIO STS:** not probed yet. Its storage docs list STS for S3-compatible
stores, and they warn that MinIO does not verify every part of a signed request, so remote signing
is unsafe on MinIO ("Use vended credentials with these stores").

**Which clients call the refresh endpoint.** This is from source at the pinned tags, not yet run:

| Client (pinned) | Calls `client.refresh-credentials-endpoint`? | Evidence |
|---|---|---|
| Spark via Iceberg Java 1.12.0 | Yes, on by default (`client.refresh-credentials-enabled` defaults to `true`); prefetches 5 min before `expires-at` | `aws/.../s3/VendedCredentialsProvider.java`, `AwsClientProperties.java:124` |
| Trino 484 | Yes, on by default; refreshes when stale | `plugin/trino-iceberg/.../S3VendedCredentialsProvider.java`, `AbstractIcebergRestVendedCredentialsProvider.java` |
| PyIceberg 0.12.0 | No automatic refresh. `RestCatalog.load_credentials()` exists, but nothing in `pyiceberg/io` re-fetches S3 credentials; a long write keeps the key it got at load time | `pyiceberg/catalog/rest/__init__.py:1104-1126`, `pyiceberg/io/pyarrow.py` |
| DuckDB 2.0.1 (iceberg extension `f979b5b28a`) | No. `IRCAPI::GetTableCredentials` (which would call `/credentials`) is defined but has no caller in that build; credentials come from `LoadTable` per transaction | `src/catalog/rest/api/catalog_api.cpp:263`; no call sites |

So the pitch's "2 of 5 clients don't refresh" surprise looks like 2 of 4 from source: PyIceberg and
DuckDB. The lab has to confirm this by running each one past the TTL.

## Compute

| What | Value | How checked |
|---|---|---|
| CPU | 4 vCPU | `nproc` |
| Memory | 15 GiB total. At boot, `free` showed ~5 GiB available because a 10 GiB hypervisor balloon (`balloon_inflate` 2,621,440 pages) counted as used; it deflated 8 GiB under load. | `free -h`, `/proc/vmstat` |
| Disk | 254 GB, 238 GB free; `/var/lib/docker` on the same disk | `df -h` |
| Virtualisation | `kvm` microVM (`nomodule`, `reboot=k panic=1`). PID 1 is `tini`, not systemd. | `systemd-detect-virt`, `/proc/cmdline` |
| OS / kernel | Ubuntu 24.04.5, Linux 6.12.113+, monolithic (no `/lib/modules`) | |

**Peak memory of the full stack** (`scripts/02-memory-bringup.sh`, `results/preflight/memory-bringup.txt`):
the sum of per-container peaks was **2,668 MiB** with MinIO, Polaris, Lakekeeper + Postgres, Trino
and Spark all up, while Trino counted `tpch.sf1.lineitem` and Spark ran SparkPi in `local[4]` with
a 2 GiB driver. Trino was 1,527 MiB, Spark 697, Polaris 284, Postgres 67, MinIO 59, Lakekeeper 33.
Host available memory afterwards was 11 GiB. The stack fits. The 50-concurrent-jobs run will need
more, but it fits within 15 GiB if jobs share one Spark and one Trino rather than one JVM each.

## Kernel

| What | Value |
|---|---|
| cgroups | v2 (`cgroup2fs`), controllers `cpuset cpu io memory hugetlb pids` |
| iptables | 1.8.10, `nf_tables` backend; a legacy `filter` table with `FORWARD DROP` also exists |
| nftables | 1.0.9, usable |
| `br_netfilter` | built in, `net.bridge.bridge-nf-call-iptables = 1` |
| sysctls changed | none |

Kind is not used, so the missing `statistic`/`recent`/`CT` iptables matches (earlier labs) don't
apply.

## Container tooling and tools

| Tool | Version |
|---|---|
| Docker | 29.10.0 client and server, rootful, `overlayfs`, `cgroupfs` driver on cgroup v2. Installed with `get.docker.com` (not pinned). |
| Docker Compose | v5.8.0 |
| Java (host) | OpenJDK 21.0.13 |
| Python (host venv) | 3.12.3; PyIceberg 0.12.0 (`[pyarrow]` extra), pyarrow 26.0.1, DuckDB 2.0.1 (iceberg `f979b5b28a`, httpfs `f71cfdb4bf`, avro `4176191c96`), boto3 |
| mc | `cgr.dev/chainguard/minio-client` (reports `DEVELOPMENT.GOGET`) |

`pyiceberg[s3fs]==0.12.0` does not install next to current boto3 (`ResolutionImpossible`; the
aiobotocore pin conflicts). PyIceberg's default `PyArrowFileIO` is what the lab uses, so this
doesn't matter for the experiment.

### Workarounds already needed (each one scripted)

1. **No systemd:** `scripts/00-host.sh` starts `dockerd` by hand.
2. **Host firewall:** the legacy `FORWARD DROP` chain dropped container-to-container traffic on the
   same Compose network (Lakekeeper's migrate step: `pool timed out while waiting for an open
   connection`; `nc lk-db 5432` timed out; 42 packets counted on the DROP policy).
   `scripts/00-host.sh` accepts `br-+` and `docker0` in the legacy `FORWARD` chain.
3. **Host-side clients:** Polaris returns the catalog's S3 endpoint (`http://minio:9000`) to clients,
   which overrides a client-side `s3.endpoint`. For the host-run probe I added `127.0.0.1 minio` to
   `/etc/hosts`. In the lab proper, clients run inside Compose.
4. **Postgres readiness:** Lakekeeper's `migrate` gets `restart: on-failure:5` because `pg_isready`
   succeeds during the image's init restart.

## Network

Docker Hub, quay.io and cgr.dev answer (401 = reachable, auth challenge); Maven Central, PyPI and
`extensions.duckdb.org` answer. Containers reach Maven Central. `ip netns` and `tc qdisc add clsact`
work (with sudo), so the "catalog down" and "STS down" tests can use `docker network disconnect`
or `tc` without further changes.

## Clock and limits

`ulimit -n` 524288. No NTP daemon (no chrony, no timesyncd). SNTP offset against time.google.com
was -0.7 s and -0.2 s (1 s resolution) on two checks. Token lifetimes are measured from
catalog-reported expiry and MinIO's own rejection time, both on one kernel clock, so sub-second
host drift doesn't enter them.

## Pins on lab day

| Component | Pitch pin | Latest on 2026-11-22 | Status |
|---|---|---|---|
| Polaris | 1.9.0 | 1.9.0 (2026-11-14) | OK, `apache/polaris@sha256:bc548500…` |
| Lakekeeper | v0.15.1 | v0.15.1 (2026-11-15) | OK, `quay.io/lakekeeper/catalog@sha256:22dcb604…` |
| Iceberg (Java) | 1.12.0 | 1.12.0 | OK, but no Spark 4.3 runtime (blocker 2) |
| Spark | 4.3.0 | 4.3.0; 4.1.4 is the newest 4.1 | **blocked** (blocker 2) |
| PyIceberg | 0.12.0 | 0.12.0 | OK |
| Trino | (not pinned) | 484 (2026-10-16) | `trinodb/trino@sha256:2704eb53…` |
| DuckDB | (not pinned) | 2.0.1 (2026-11-20) | OK |
| MinIO | (not pinned) | upstream frozen at RELEASE.2025-10-15T17-29-55Z, no images | **blocked** (blocker 1) |
| Postgres (Lakekeeper) | | 17, `postgres@sha256:223efeb1…` | |
