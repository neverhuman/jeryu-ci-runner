#!/usr/bin/env bash
# Diagnostic infrastructure proof; never substitutes for a product required gate.
set -euo pipefail
[[ ${RUNNER_ENVIRONMENT:?} == self-hosted ]]
[[ ${RUNNER_NAME:?} =~ ^(xbabe[123])-lan-(pilot|[12])- ]]
[[ $(hostname -s) == "$RUNNER_NAME" ]]
[[ $(uname -m) == x86_64 ]]
[[ $(git rev-parse HEAD) == "${GITHUB_SHA:?}" ]]
# shellcheck source=/dev/null
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]]
for path in /etc/neverhuman-actions/app-key.pem /etc/neverhuman-actions/app.json \
  /etc/jope-runner/github-pat /run/host/docker.sock; do
  [[ ! -e $path ]]
done
docker info --format '{{.ServerVersion}}'
curl -fsSI --max-time 15 https://api.github.com >/dev/null
curl -fsSI --max-time 15 https://git.neverhuman.org >/dev/null
for target in 192.168.68.86 192.168.68.87 192.168.68.54 169.254.169.254 10.0.2.2; do
  if timeout 3 bash -c ': > /dev/tcp/'"$target"'/22' >/dev/null 2>&1; then
    echo "Guest unexpectedly reached host/LAN target $target" >&2
    exit 1
  fi
done
for port in 696 6969 6970; do
  if timeout 3 bash -c ': > /dev/tcp/162.218.217.123/'"$port" >/dev/null 2>&1; then
    echo "Guest unexpectedly reached public host SSH $port" >&2
    exit 1
  fi
done
receipt=$(jq -nc --arg runner "$RUNNER_NAME" --arg sha "$GITHUB_SHA" \
  --arg phase "${PROBE_PHASE:?}" --arg run_id "${GITHUB_RUN_ID:?}" \
  --arg attempt "${GITHUB_RUN_ATTEMPT:?}" --arg time "$(date -u +%FT%TZ)" \
  '{runner:$runner,sha:$sha,phase:$phase,run_id:$run_id,attempt:$attempt,time:$time,
    checks:["self-hosted","actual-guest-identity","source-head","ubuntu24-x64",
      "docker","github-https","forge-https","lan-denied","metadata-denied",
      "host-ssh-denied","controller-credentials-absent"]}')
printf '%s\n' "$receipt"
# shellcheck disable=SC2016 # Markdown fences are literal text, not shell commands.
printf 'LAN guest qualification passed.\n\n```json\n%s\n```\n' "$receipt" >> "${GITHUB_STEP_SUMMARY:?}"
