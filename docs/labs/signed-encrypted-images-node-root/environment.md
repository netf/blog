# Environment preflight

Recorded 2026-10-15 by `scripts/01-preflight.sh` (raw output in `results/preflight/`),
following report.md section 6. The preflight never opens `/dev/kvm` or starts a VM.

## Compute

- 4 vCPU (Intel Xeon), 16 GB RAM of which ~4.8 GB is available (`MemAvailable` 5,063,004 kB;
  ~10 GB is held by the host balloon), no swap.
- Disk: 254 GB, 246 GB free; `/var/lib/docker` is on the same disk.
- `systemd-detect-virt` = `kvm`. The kernel cmdline (`reboot=k panic=1 nomodule`, virtio-mmio
  root, `ip=` set by the VMM) is a Firecracker microVM.
- PID 1 is `tini`, not systemd: nothing starts `dockerd` and `timedatectl` can't report NTP.

## Kernel and containers

- Kernel 6.12.94+, cgroup v2 (`cgroup2fs`; controllers cpuset cpu io memory hugetlb pids).
- Monolithic kernel: no `/lib/modules`, `/proc/modules` empty. `overlay` and `nf_conntrack`
  are built in. Nothing this lab needs is a loadable module.
- Docker 29.9.1 on the first VM, 29.9.2 on the second (get.docker.com is not pinned); overlayfs storage driver, cgroupfs, cgroup v2, rootful.
- iptables 1.8.10 with the nf_tables backend, but a legacy `filter` table also exists with
  `FORWARD DROP`. That is the dual-backend problem the Istio lab documented, fixed by the same
  `scripts/02b-host-iptables-fix.sh`.
- Throwaway `kind create cluster` (Kind v0.33.0) came up Ready: Kubernetes v1.37.0,
  containerd 2.3.4, Debian 13 node image
  `kindest/node@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5`.
- Host egress: Docker Hub, ghcr.io and GitHub reachable.

## Confidential computing (read-only checks, `results/preflight/tee.txt`)

- CPU flags: `vmx` and `hypervisor` present; `sev`, `sev_es`, `sev_snp`, `tdx_guest`, `sgx` absent.
  This guest has no TEE hardware of its own.
- `/sys/hypervisor` does not exist; dmesg shows `Hypervisor detected: KVM`.
- `/dev/kvm` exists, but `/dev/vhost-vsock` and `/dev/vhost-net` do not.
- A previous run on this VM type found that `KVM_CREATE_VCPU` triggers
  `kernel BUG at arch/x86/kvm/x86.c:702` (`kvm_spurious_fault`): nested virtualisation is
  advertised but broken. Kata/Confidential Containers cannot run here, so this lab does not try
  and does not run any KVM, QEMU or Kata probe. That is why TEEs are part 2.

## Workarounds applied (none change what is measured)

1. `scripts/00b-start-dockerd.sh` starts `dockerd` by hand (no systemd).
2. `/var/run/docker.sock` is made world-writable on this throwaway VM so Kind runs without sudo.
3. `scripts/02b-host-iptables-fix.sh` (copied from the Istio lab) accepts Kind bridge traffic in
   the legacy `FORWARD` chain.

## Second run (2026-10-22)

The first VM was recycled mid-lab. The second VM had the same shape (4 vCPU, 16 GB, kernel
6.12.94+, same CPU flags, no `/sys/hypervisor`); `results/preflight/` holds its preflight. The
whole lab was rebuilt from `reproduce.sh`'s steps; keys and digests differ from the first run.
