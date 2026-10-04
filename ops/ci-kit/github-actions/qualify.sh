#!/usr/bin/env bash
# Live VM qualification without granting it access to any GitHub repository.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
nh_require_root
NH_INSTANCE="qualify-$NH_HOST-$(date -u +%Y%m%d%H%M%S)"
NH_UNIT="neverhuman-$NH_INSTANCE"
NH_PORT=22610
nh_prepare_job_dir
trap 'nh_vm_stop' EXIT
qemu-img create -q -f qcow2 -F qcow2 -b "$NH_GOLD_IMAGE" "$NH_JOB/disk.qcow2" 80G
printf '#cloud-config\nssh_pwauth: false\n' > "$NH_JOB/user-data"
nh_seed "$NH_JOB/user-data"
nh_vm_start "$NH_JOB/disk.qcow2" "$NH_JOB/seed.img" 4 4096
deadline=$((SECONDS + 300))
until nh_guest_ssh true >/dev/null 2>&1; do
  [[ $SECONDS -lt $deadline ]] && systemctl is-active --quiet "$NH_UNIT" || exit 1
  sleep 3
done
nh_guest_ssh 'sudo cloud-init status --wait >/dev/null; /opt/actions-runner/bin/Runner.Listener --version; docker info --format "{{.ServerVersion}}"; curl -fsSI --max-time 15 https://api.github.com >/dev/null' > "$NH_JOB/qualification.log"
nh_guest_ssh "bash -s" >> "$NH_JOB/qualification.log" <<'GUEST'
set -euo pipefail
for target in 192.168.68.86 192.168.68.87 192.168.68.54 169.254.169.254 10.0.2.2; do
  if timeout 3 bash -c ': > /dev/tcp/'"$target"'/22' >/dev/null 2>&1; then
    echo "Unexpected host/LAN access: $target" >&2; exit 1
  fi
  echo "Host/LAN connection blocked: $target"
done
for port in 696 6969 6970; do
  if timeout 3 bash -c ': > /dev/tcp/162.218.217.123/'"$port" >/dev/null 2>&1; then
    echo "Unexpected public SSH access: $port" >&2; exit 1
  fi
  echo "Public SSH connection blocked: $port"
done
curl -fsSI --max-time 15 https://git.neverhuman.org >/dev/null
test ! -e /etc/neverhuman-actions/app-key.pem
test ! -e /etc/jope-runner/github-pat
test ! -S /run/host/docker.sock
echo 'Runner binary, Docker, GitHub HTTPS, forge HTTPS and credential boundary qualified'
GUEST
nft -j list table inet neverhuman_actions > "$NH_JOB/egress-evidence.json"
jq -e '[..|objects|select(has("counter"))|.counter.packets] | add > 0' "$NH_JOB/egress-evidence.json" >/dev/null
nh_vm_stop
sha=$(sha256sum "$NH_JOB/qualification.log" | cut -d' ' -f1)
jq -n --arg host "$NH_HOST" --arg time "$(date -u +%FT%TZ)" --arg log_sha256 "$sha" \
  '{phase:"vm-qualified",host:$host,time:$time,log_sha256:$log_sha256,runner_registered:false,checks:["runner-version","docker","github-https","forge-https","lan-denied","metadata-denied","host-ssh-denied","controller-credentials-absent"]}' \
  > "$NH_STATE/receipts/vm-qualified.json"
echo "VM boundary qualified on $NH_HOST"
