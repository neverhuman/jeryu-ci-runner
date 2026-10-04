#!/usr/bin/env bash
# Owner-browser bootstrap only: one ephemeral listener, no long-lived API credential.
# The org group must remain closed until repository-access approval is complete.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
nh_require_root
IFS= read -r token
[[ $token =~ ^[A-Za-z0-9_-]{20,}$ ]] || exit 2
rm -- "$NH_CONFIG/registration-token"
[[ -f $NH_STATE/receipts/vm-qualified.json ]] || { echo 'Live VM qualification is required' >&2; exit 2; }
NH_INSTANCE="$NH_HOST-lan-pilot-$(date -u +%Y%m%d%H%M%S)"
NH_UNIT="neverhuman-$NH_INSTANCE"
NH_PORT=22611
nh_prepare_job_dir
trap 'nh_vm_stop' EXIT
qemu-img create -q -f qcow2 -F qcow2 -b "$NH_GOLD_IMAGE" "$NH_JOB/disk.qcow2" 80G
printf '#cloud-config\nssh_pwauth: false\n' > "$NH_JOB/user-data"
nh_seed "$NH_JOB/user-data"
nh_vm_start "$NH_JOB/disk.qcow2" "$NH_JOB/seed.img" 8 8192
deadline=$((SECONDS + 300))
until nh_guest_ssh true >/dev/null 2>&1; do
  if [[ $SECONDS -ge $deadline ]] || ! systemctl is-active --quiet "$NH_UNIT"; then echo 'Guest boot failed' >&2; exit 1; fi
  sleep 3
done
nh_guest_ssh 'sudo cloud-init status --wait >/dev/null'
# shellcheck disable=SC2016 # Registration token is expanded inside the guest only.
printf '%s\n' "$token" | nh_guest_ssh 'read -r token; cd /opt/actions-runner; ./config.sh --unattended --ephemeral --url https://github.com/neverhuman --token "$token" --runnergroup neverhuman-lan --labels lan-ci,ubuntu24 --name '"$NH_INSTANCE"' --work _work' > "$NH_JOB/registration.log" 2>&1
unset token
runner_id=$(nh_guest_ssh 'cat /opt/actions-runner/.runner' | jq -er '.agentId')
expected=$(jq -er '.image_sha256' "$NH_STATE/receipts/image-prepared.json")
jq -n --arg host "$NH_HOST" --arg name "$NH_INSTANCE" --argjson runner_id "$runner_id" \
  --arg image_sha256 "$expected" --arg time "$(date -u +%FT%TZ)" \
  '{phase:"pilot-listener",host:$host,name:$name,runner_id:$runner_id,image_sha256:$image_sha256,time:$time,ephemeral:true,automatic_replacement:false,group:"neverhuman-lan"}' \
  > "$NH_STATE/receipts/pilot-listener.json"
echo "Registered shared pilot runner $runner_id on $NH_HOST; automatic replacement awaits app setup"
nh_guest_ssh 'cd /opt/actions-runner; export AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache RUNNER_TOOL_CACHE=/opt/hostedtoolcache; ./run.sh' > "$NH_JOB/runner.log" 2>&1
