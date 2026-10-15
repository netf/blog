#!/usr/bin/env bash
# Environment preflight (report.md section 6). Read-only: never opens /dev/kvm
# or starts a VM (an earlier KVM probe on this VM type hit a host kernel BUG).
set -uo pipefail
export PATH="$HOME/bin:/usr/local/go/bin:$PATH"
OUT="$(cd "$(dirname "$0")/.." && pwd)/results/preflight"
mkdir -p "$OUT"
sec() { echo; echo "## $1"; }
{
sec compute; nproc; free -h; df -h /; systemd-detect-virt
grep -E 'MemTotal|MemAvailable' /proc/meminfo
sec kernel; uname -r; stat -fc %T /sys/fs/cgroup
cat /sys/fs/cgroup/cgroup.controllers
sec modules; ls /lib/modules 2>&1; wc -l < /proc/modules
ls /sys/module | grep -E '^(overlay|br_netfilter|nf_conntrack|nf_tables)$'
sec limits; ulimit -n; timedatectl show -p NTPSynchronized 2>&1
} > "$OUT/host.txt" 2>&1
{
sec docker; sudo docker version --format 'client {{.Client.Version}} server {{.Server.Version}}'
sudo docker info 2>/dev/null | grep -E 'Storage Driver|Cgroup|Runtimes|Root Dir'
sec iptables; sudo iptables -V; sudo iptables-legacy -S FORWARD 2>&1 | head -3
sudo nft list tables 2>&1 | head
sec tools; kind version; kubectl version --client 2>&1 | head -1
helm version --short; cosign version 2>&1 | grep GitVersion
syft version 2>&1 | grep -E '^Version'; skopeo --version; go version
gdb --version | head -1; jq --version
sec egress
for u in https://registry-1.docker.io/v2/ https://ghcr.io/v2/ https://github.com; do
  curl -s -m 10 -o /dev/null -w "$u %{http_code}\n" "$u"; done
} > "$OUT/tooling.txt" 2>&1
# TEE / CoCo readiness, read-only. No ioctls, no VMs.
{
sec cpu-model; grep -m1 'model name' /proc/cpuinfo
sec cpu-flags-of-interest
for f in vmx svm hypervisor sev sev_es sev_snp tdx_guest sgx; do
  printf '%-11s %s\n' "$f" "$(grep -m1 -ow "$f" /proc/cpuinfo || echo absent)"; done
sec sys-hypervisor; ls -la /sys/hypervisor 2>&1; cat /sys/hypervisor/type 2>&1
sec dmi; cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>&1
sec cmdline; cat /proc/cmdline
sec devices; ls -l /dev/kvm /dev/vhost-vsock /dev/vhost-net /dev/sev /dev/tdx_guest 2>&1
sec dmesg-boot-hints; sudo dmesg | grep -i -E 'firecracker|hypervisor detected|virtio_mmio|tdx|sev' | head -10
sec dmesg-kvm-bugs-so-far; sudo dmesg | grep -c 'kvm_spurious_fault'
} > "$OUT/tee.txt" 2>&1
echo "wrote $OUT"
