#!/usr/bin/env bash
# The runner answers git's credential requests for the forge as itself, from its token file, even when
# HOME's global git config names a helper that fails; the token is in no argv.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
runner=${1:-$script_dir/pr-gate-runner.sh}
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^GIT_CONFIG' || true)
awk '/^GIT_HELPER=/,/^git_env=\(/' "$runner" | sed '/^git_env=(/,$d' >"$fixture/block.sh"
[[ -s "$fixture/block.sh" ]]
printf 'synthetic-token\n' >"$fixture/token"
chmod 0600 "$fixture/token"
# A global helper that fails the way the host's personal one did.
printf '#!/bin/sh\necho "fatal: broken helper" >&2\nexit 1\n' >"$fixture/broken"
chmod +x "$fixture/broken"
export HOME="$fixture/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
git config --global credential.helper "$fixture/broken"
git config --global "credential.https://forge.invalid.helper" "$fixture/broken"
BASE=https://forge.invalid IDENTITY=runner-bot TOKEN_FILE=$fixture/token
# shellcheck source=/dev/null
source "$fixture/block.sh"
answer=$(printf 'protocol=https\nhost=forge.invalid\npath=git/acme/private.git\n\n' | git credential fill)
grep -qx 'username=runner-bot' <<<"$answer" || { printf 'FAIL: wrong username:\n%s\n' "$answer" >&2; exit 1; }
grep -qx 'password=synthetic-token' <<<"$answer" || { printf 'FAIL: wrong password\n' >&2; exit 1; }
grep -q 'synthetic-token' <<<"$GIT_CONFIG_VALUE_1" && { printf 'FAIL: token in config value\n' >&2; exit 1; }
printf 'PASS git credential: forge answered as the runner with a broken global helper\n'
