#!/usr/bin/env bash
# Credential-free profile build from the qualified base; never from a job disk.
set -euo pipefail
# shellcheck source=common.sh
source /opt/neverhuman-actions/common.sh
nh_require_root
exec 9>"$NH_STATE/image-build.lock"
flock -n 9 || exit 2
browser_image=$NH_STATE/images/runner-ubuntu24-x64-browser158.qcow2
browser_receipt=$NH_STATE/receipts/image-browser158-prepared.json
[[ ! -e $browser_image && ! -e $browser_receipt ]] || exit 2
[[ $(awk '/MemAvailable:/ {print $2}' /proc/meminfo) -ge 12582912 ]] || exit 2
[[ $(df --output=avail -BG "$NH_STATE" | tail -n1 | tr -dc '0-9') -ge 100 ]] || exit 2
nft list table inet neverhuman_actions >/dev/null
expected=$(jq -er '.image_sha256' "$NH_STATE/receipts/image-prepared.json")
printf '%s  %s\n' "$expected" "$NH_GOLD_IMAGE" | sha256sum -c - >/dev/null
NH_INSTANCE="image-browser158-$NH_HOST-$(date -u +%Y%m%d%H%M%S)"
NH_UNIT="neverhuman-$NH_INSTANCE"
NH_PORT=22612
nh_prepare_job_dir
trap 'nh_vm_stop' EXIT
qemu-img create -q -f qcow2 -F qcow2 -b "$NH_GOLD_IMAGE" "$NH_JOB/disk.qcow2" 80G
printf '#cloud-config\nssh_pwauth: false\n' > "$NH_JOB/user-data"
nh_seed "$NH_JOB/user-data"
nh_vm_start "$NH_JOB/disk.qcow2" "$NH_JOB/seed.img" 8 8192
deadline=$((SECONDS + 300))
until nh_guest_ssh true >/dev/null 2>&1; do
  [[ $SECONDS -lt $deadline ]] && systemctl is-active --quiet "$NH_UNIT" || exit 1
  sleep 3
done
nh_guest_ssh 'sudo cloud-init status --wait >/dev/null'
# Only public Python/browser inputs enter this guest. No repo checkout or GHA token.
if ! nh_guest_ssh 'timeout 3600 bash -se' > "$NH_JOB/browser-image.log" 2>&1 <<'GUEST'
python3 -m venv /home/runner/.browser-image-build
/home/runner/.browser-image-build/bin/python -m pip install playwright==1.58.0
# Extract public, digest-verified browser files; never execute the container.
image=mcr.microsoft.com/playwright/python@sha256:cd8493e380df200a471821e2690b710eab8d793dde3c0946fd0a39a961022914
docker pull --platform linux/amd64 "$image"
container=$(docker create "$image")
mkdir -p /home/runner/.cache/ms-playwright
docker cp "$container:/ms-playwright/." /home/runner/.cache/ms-playwright/
docker rm "$container"
sudo chown -R runner:runner /home/runner/.cache/ms-playwright
docker image rm "$image"
/home/runner/.browser-image-build/bin/python -m playwright install --with-deps chromium
/home/runner/.browser-image-build/bin/python -c 'from playwright.sync_api import sync_playwright; import os; p=sync_playwright().start(); assert os.path.isfile(p.chromium.executable_path); b=p.chromium.launch(); print(b.version); b.close(); p.stop()'
test ! -e /etc/neverhuman-actions/app-key.pem
test ! -e /etc/neverhuman-actions/app.json
GUEST
then
  echo "Browser profile build failed; inspect $NH_JOB/browser-image.log" >&2
  exit 1
fi
nh_guest_ssh 'sudo cloud-init clean --logs; sudo poweroff' || true
shutdown_deadline=$((SECONDS + 60))
while systemctl is-active --quiet "$NH_UNIT" && [[ $SECONDS -lt $shutdown_deadline ]]; do sleep 1; done
systemctl is-active --quiet "$NH_UNIT" && exit 1
qemu-img convert -q -O qcow2 "$NH_JOB/disk.qcow2" "$browser_image.part"
chmod 0444 "$browser_image.part"
mv "$browser_image.part" "$browser_image"
sha=$(sha256sum "$browser_image" | cut -d' ' -f1)
jq -n --arg host "$NH_HOST" --arg image_sha256 "$sha" --arg source_image_sha256 "$expected" --arg image_path "$browser_image" --arg time "$(date -u +%FT%TZ)" '{phase:"image-browser158-prepared",host:$host,image_sha256:$image_sha256,source_image_sha256:$source_image_sha256,image_path:$image_path,time:$time,playwright_version:"1.58.0",browser_artifact_digest:"sha256:cd8493e380df200a471821e2690b710eab8d793dde3c0946fd0a39a961022914",browser_launch_verified:true,runner_registered:false,job_credentials_absent:true}' > "$browser_receipt"
rm -- "$NH_JOB/disk.qcow2" "$NH_JOB/seed.img"
echo "Browser profile prepared on $NH_HOST; controller activation still requires boundary qualification"
