# Incidents during the lab run

## 2026-11-22 12:24:16Z to 12:35:56Z: the VM was paused for about 11 minutes 40 seconds

Evidence:
- `dmesg`: `[ 8145.884869] random: crng reseeded due to virtual machine fork` (the hypervisor
  snapshotted or paused the guest).
- `results/matrix/docker-stats.tsv` (one sample of every container every ~30 s): last sample before
  the gap 12:24:01Z, next 12:36:01Z.
- MinIO audit log: no request between 12:24:16Z and 12:35:56Z (the only gap over 60 s in the window).
- Job logs: PyIceberg and DuckDB jobs log one line a minute; nothing between 12:24:1xZ and resume.
- Trino: every running task failed at 12:35:56Z with `ABANDONED_TASK ... has not been accessed since
  2026-11-22T12:24:28Z`, including arm A (no vended credentials at all).

Effect: processes stopped, wall clock did not. Every job that was running at 12:24 is discarded:
the matrix's 120-minute jobs (all arms, all engines) and failure test F1b (catalog down from minute 8
to minute 14). They were rerun with the same configuration; the reruns are what the post reports.
Jobs that finished before 12:24 (all 5, 30 and 61-minute matrix jobs; F0, F3, F4, F1a, the
Lakekeeper canary) are unaffected.

## All VM pauses seen (gaps in the 30-second docker-stats sampler, `results/matrix/docker-stats.tsv`)

| Gap in samples | Approx. frozen time | What was running |
|---|---|---|
| 11:22:33 to 11:24:21 | ~80 s | matrix (30/61/120), phase 1 (F0, F3, F4, Lakekeeper canary) |
| 11:52:08 to 11:54:07 | ~90 s | matrix (61/120), phase 2 (F1a, catalog already down) |
| 12:24:01 to 12:36:01 | ~11 min 40 s | matrix (120), phase 3 (F1b) |
| 12:50:27 to 12:52:40 | ~100 s | nothing measured |

`dmesg` shows `random: crng reseeded due to virtual machine fork` at uptime 6312 s, 8145 s and 9048 s.
The pauses look periodic (about every 30 minutes; this is the platform's VM snapshotting, not
something the lab controls).

How results are treated:
- Short pauses (~1.5 min) hit every concurrently running job equally. They stretch elapsed times
  (a "30-minute" job took 31.3 min, a "61-minute" job 63.8 min in every arm), so job-time
  overhead is only compared between arms that ran at the same moment. No refresh-capable client
  failed across a short pause: the 5-minute prefetch margin covers it.
- The 11 min 40 s pause is longer than the 5-minute prefetch margin, so it is discarded (see above).
  Unplanned observation, not reported as a result: after resume, the PyIceberg shim's refresh got a
  credential that had expired 208 s earlier ("new expiry in -208s"). Polaris served it from its
  credential cache, whose expiry apparently runs on a monotonic clock that stopped during the pause
  while STS expiry runs on wall time. This is the clock-discontinuity case the plan dropped; it
  would need its own test.
- Reruns get their pause overlap annotated from their own sampler.

## 2026-11-22 13:54:21Z to about 14:06:40Z: a second long pause (about 12 minutes)

`dmesg`: `[12759.159759] random: crng reseeded due to virtual machine fork`. Processes started at
13:01:27 showed 53 minutes of elapsed (monotonic) time at 14:06 wall clock.

It hit the rerun of the 120-minute jobs 53 minutes in. Again every Trino query failed with
`ABANDONED_TASK` the moment the VM resumed, and the PyIceberg jobs in B and C failed on keys that had
expired while frozen. Two pauses longer than the 5-minute refresh margin within 100 minutes mean a
clean 120-minute run isn't achievable on this VM, so I stopped the rerun at 14:07Z instead of
retrying. **The post reports no 120-minute result.** The first 53 minutes of the rerun (13:01:27 to
13:54:21, no other tests against those catalogs) are used only for catalog call counts per job
(`results/matrix-120/catalog-calls-first-53min.txt`).

The failure-test phase running at the time (F2, STS unreachable) had already finished measuring:
all three of its jobs failed between 13:46 and 13:52, before the pause. Its scheduled "STS UP" fell
inside the pause, so `sts-f` was reconnected by hand at 14:07 (logged in `failure/events.log`).

Options for the 120-minute jobs (for Piotr): rerun them on a host without periodic snapshot pauses
(any workstation or a CI runner with 16 GB), or accept 61 minutes as the longest job. The 61-minute
jobs already cross the TTL in both vended arms (4 times at TTL 900 s).
