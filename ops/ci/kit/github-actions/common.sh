#!/usr/bin/env bash
# Host controller settings. No job receives the controller's private keys.
# shellcheck disable=SC2034 # Settings are consumed by the sourcing controller scripts.
set -euo pipefail
NH_STATE=/var/lib/neverhuman-actions
NH_CONFIG=/etc/neverhuman-actions
NH_RUNNER_VERSION=2.337.0
NH_RUNNER_SHA256=70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613
NH_CLOUD_SHA256=6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2
NH_CLOUD_IMAGE=$NH_STATE/images/noble-20260926-amd64.img
NH_GOLD_IMAGE=$NH_STATE/images/runner-ubuntu24-x64.qcow2
NH_HOST=$(hostname -s)
case "$NH_HOST" in xbabe1|xbabe2|xbabe3) ;; *) echo "Unapproved physical host: $NH_HOST" >&2; exit 2 ;; esac

nh_require_root() { [[ $(id -u) == 0 ]] || { echo 'Root controller required' >&2; exit 2; }; }

nh_guest_ssh() {
  ssh -i "$NH_CONFIG/guest-key" -p "$NH_PORT" -o BatchMode=yes -o ConnectTimeout=3 \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$NH_JOB/known_hosts" \
    runner@127.0.0.1 "$@"
}

nh_vm_start() {
  local image=$1 seed=$2 cpus=$3 memory=$4
  systemd-run --quiet --unit "$NH_UNIT" --collect \
    -p User=neverhuman-vm -p Group=neverhuman-vm -p SupplementaryGroups=kvm \
    -p "MemoryMax=$((memory + 1024))M" -p "CPUQuota=$((cpus * 100))%" -p TasksMax=256 \
    /usr/bin/qemu-system-x86_64 -enable-kvm -cpu host -smp "$cpus" -m "$memory" \
    -display none -serial "file:$NH_JOB/serial.log" -monitor none \
    -drive "file=$image,format=qcow2,if=virtio" \
    -drive "file=$seed,format=raw,if=virtio,readonly=on" \
    -netdev "user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:$NH_PORT-:22" \
    -device virtio-net-pci,netdev=net0,mac=52:54:00:ab:ba:01 -no-reboot
}

nh_vm_stop() { if systemctl is-active --quiet "$NH_UNIT"; then systemctl stop "$NH_UNIT"; fi; }

nh_seed() {
  local user_data=$1
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$NH_INSTANCE" "$NH_INSTANCE" > "$NH_JOB/meta-data"
  cat > "$NH_JOB/network-config" <<'NET'
version: 2
ethernets:
  ci:
    match:
      macaddress: '52:54:00:ab:ba:01'
    dhcp4: true
    dhcp4-overrides:
      use-dns: false
    nameservers:
      addresses: [1.1.1.1, 8.8.8.8]
NET
  cloud-localds --network-config="$NH_JOB/network-config" "$NH_JOB/seed.img" "$user_data" "$NH_JOB/meta-data"
  chown -R neverhuman-vm:neverhuman-vm "$NH_JOB"
}

nh_prepare_job_dir() {
  [[ $NH_INSTANCE =~ ^[a-z0-9-]+$ ]] || exit 2
  NH_JOB=$NH_STATE/jobs/$NH_INSTANCE
  [[ ! -e $NH_JOB ]] || { echo 'Instance directory already exists' >&2; exit 2; }
  install -d -m 0750 -o neverhuman-vm -g neverhuman-vm "$NH_JOB"
}
