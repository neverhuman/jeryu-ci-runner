#!/usr/bin/env bash
# Live VM qualification without granting it access to any GitHub repository.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
nh_require_root
expected=$(jq -er '.image_sha256' "$NH_IMAGE_RECEIPT")
printf '%s  %s\n' "$expected" "$NH_GOLD_IMAGE" | sha256sum -c - >/dev/null
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
# The label must describe the actual guest, never merely its filename.
# shellcheck disable=SC2016 # The guest expands its own OS metadata.
ubuntu_version=$(nh_guest_ssh 'source /etc/os-release; printf "%s" "$VERSION_ID"')
[[ $ubuntu_version == "$NH_UBUNTU_VERSION" ]] || { echo "Guest OS capability mismatch" >&2; exit 2; }
printf 'Ubuntu version qualified: %s\n' "$ubuntu_version" >> "$NH_JOB/qualification.log"
browser=false
if [[ $(jq -r '.playwright_version // empty' "$NH_IMAGE_RECEIPT") == 1.58.0 ]]; then
  nh_guest_ssh '/home/runner/.browser-image-build/bin/python -c '\''from playwright.sync_api import sync_playwright; p=sync_playwright().start(); b=p.chromium.launch(); print(b.version); b.close(); p.stop()'\''' >> "$NH_JOB/qualification.log"
  browser=true
fi
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
test ! -e /etc/neverhuman-actions/app.json
test ! -e /etc/jope-runner/github-pat
test ! -S /run/host/docker.sock
echo 'Runner binary, Docker, GitHub HTTPS, forge HTTPS and credential boundary qualified'
GUEST
nft -j list table inet neverhuman_actions > "$NH_JOB/egress-evidence.json"
jq -e '[..|objects|select(has("counter"))|.counter.packets] | add > 0' "$NH_JOB/egress-evidence.json" >/dev/null
nh_vm_stop
systemctl is-active --quiet "$NH_UNIT" && exit 1
rm -- "$NH_JOB/disk.qcow2" "$NH_JOB/seed.img"
sha=$(sha256sum "$NH_JOB/qualification.log" | cut -d' ' -f1)
jq -n --arg host "$NH_HOST" --arg image_sha256 "$expected" --argjson browser "$browser" --arg ubuntu_version "$ubuntu_version" --arg time "$(date -u +%FT%TZ)" --arg log_sha256 "$sha" \
  '{phase:"vm-qualified",host:$host,image_sha256:$image_sha256,browser158:$browser,ubuntu_version:$ubuntu_version,time:$time,log_sha256:$log_sha256,runner_registered:false,workspace_destroyed:true,checks:(["ubuntu-version","runner-version","docker","github-https","forge-https","lan-denied","metadata-denied","host-ssh-denied","controller-credentials-absent"] + (if $browser then ["browser158-launch"] else [] end))}' \
  > "$NH_QUALIFICATION_RECEIPT"
echo "VM boundary qualified on $NH_HOST"
