#!/usr/bin/env bash
# One new VM and one ephemeral runner per job. No host files are mounted in it.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
nh_require_root
lane=${1:?lane must be 1 or 2}
case "$lane" in 1|2) ;; *) exit 2 ;; esac
exec 9>"$NH_STATE/lane-$lane.lock"
flock -n 9 || { echo 'Lane already owned' >&2; exit 2; }
[[ -f $NH_GOLD_IMAGE && -f $NH_STATE/receipts/image-prepared.json ]] || exit 2
expected=$(jq -er '.image_sha256' "$NH_STATE/receipts/image-prepared.json")
printf '%s  %s\n' "$expected" "$NH_GOLD_IMAGE" | sha256sum -c - >/dev/null
[[ $(df --output=avail -BG "$NH_STATE" | tail -n1 | tr -dc '0-9') -ge 100 ]] || { echo 'Disk admission refused' >&2; exit 2; }
available=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
[[ $available -ge 12582912 ]] || { echo 'Memory admission refused' >&2; exit 2; }
nft list table inet neverhuman_actions >/dev/null || { echo 'Egress policy unavailable' >&2; exit 2; }
NH_INSTANCE="$NH_HOST-lan-$lane-$(date -u +%Y%m%d%H%M%S)-$RANDOM"
NH_UNIT="neverhuman-$NH_INSTANCE"
NH_PORT=$((22600 + lane))
nh_prepare_job_dir
trap 'nh_vm_stop' EXIT
qemu-img create -q -f qcow2 -F qcow2 -b "$NH_GOLD_IMAGE" "$NH_JOB/disk.qcow2" 80G
cat > "$NH_JOB/user-data" <<'CLOUD'
#cloud-config
ssh_pwauth: false
write_files:
  - path: /etc/profile.d/neverhuman-ci.sh
    permissions: '0644'
    content: |
      export AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache
      export RUNNER_TOOL_CACHE=/opt/hostedtoolcache
CLOUD
nh_seed "$NH_JOB/user-data"
nh_vm_start "$NH_JOB/disk.qcow2" "$NH_JOB/seed.img" 8 8192
deadline=$((SECONDS + 300))
until nh_guest_ssh true >/dev/null 2>&1; do
  if [[ $SECONDS -ge $deadline ]] || ! systemctl is-active --quiet "$NH_UNIT"; then echo 'Guest boot failed' >&2; exit 1; fi
  sleep 3
done
nh_guest_ssh 'sudo cloud-init status --wait >/dev/null'
body=$(jq -nc --arg name "$NH_INSTANCE" '{name:$name,runner_group_id:3,labels:["self-hosted","linux","x64","lan-ci","ubuntu24"],work_folder:"_work"}')
response=$(printf '%s' "$body" | bash "$(dirname "${BASH_SOURCE[0]}")/api.sh" POST /orgs/neverhuman/actions/runners/generate-jitconfig)
runner_id=$(jq -er '.runner.id' <<< "$response")
jit=$(jq -er '.encoded_jit_config' <<< "$response")
receipt=$NH_STATE/receipts/$NH_INSTANCE.json
jq -n --arg host "$NH_HOST" --arg instance "$NH_INSTANCE" --arg image_sha256 "$expected" \
  --argjson runner_id "$runner_id" --arg time "$(date -u +%FT%TZ)" \
  '{phase:"runner-started",host:$host,instance:$instance,runner_id:$runner_id,image_sha256:$image_sha256,time:$time,ephemeral:true,group:"neverhuman-lan"}' > "$receipt"
echo "Runner $runner_id started on physical host $NH_HOST instance=$NH_INSTANCE"
set +e
# shellcheck disable=SC2016 # The guest shell expands the single-use JIT config.
printf '%s' "$jit" | nh_guest_ssh 'cd /opt/actions-runner; read -r -d "" jit || true; export AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache RUNNER_TOOL_CACHE=/opt/hostedtoolcache; ./run.sh --jitconfig "$jit"' > "$NH_JOB/runner.log" 2>&1
result=$?
set -e
nh_vm_stop
systemctl is-active --quiet "$NH_UNIT" && { echo 'VM failed to stop; retaining instance for investigation' >&2; exit 1; }
rm -- "$NH_JOB/disk.qcow2" "$NH_JOB/seed.img"
jq --arg time "$(date -u +%FT%TZ)" --argjson controller_exit "$result" \
  '.phase="runner-stopped" | .completed_at=$time | .controller_exit=$controller_exit | .workspace_destroyed=true' "$receipt" > "$receipt.part"
mv "$receipt.part" "$receipt"
# Logs/receipts remain on the host; only this newly generated job disk is removed.
echo "Runner $runner_id ended controller_exit=$result; VM stopped"
exit "$result"
