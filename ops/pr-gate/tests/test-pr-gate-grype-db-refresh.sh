#!/usr/bin/env bash
# Exercise pr-gate-grype-db-refresh.sh with a stub grype that records its arguments; no network.
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GRYPE_)' || true)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
refresh="$script_dir/pr-gate-grype-db-refresh.sh"
unit_dir="$script_dir/../systemd"
fx=$(mktemp -d)
trap 'rm -rf -- "$fx"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tools="$fx/home/gate-runner/governed-tools/bin"
mkdir -p "$tools" "$fx/empty"
cat >"$tools/grype" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$fx/grype.log"
[[ ! -e "$fx/offline" ]]
SH
chmod +x "$tools/grype"
run() { HOME="$fx/home" PATH="$fx/empty:/usr/bin:/bin" bash "$refresh"; }

run || fail 'refresh with the governed grype failed'
[[ "$(cat "$fx/grype.log")" == "db update --quiet" ]] || fail "unexpected grype call: $(cat "$fx/grype.log")"
printf 'PASS governed grype asked to update its own database\n'

touch "$fx/offline"
if run 2>/dev/null; then fail 'a failed update was reported as success'; fi
rm "$fx/offline"
printf 'PASS a failed update fails the oneshot, so systemd shows it\n'

rm "$tools/grype"
run 2>"$fx/err" || fail 'missing grype should be a no-op'
grep -q 'grype not found' "$fx/err" || fail 'missing grype not reported'
printf 'PASS no grype installed: nothing to refresh\n'

grep -qx 'ExecStart=%h/gate-runner/bin/pr-gate-grype-db-refresh.sh' "$unit_dir/pr-gate-grype-db-refresh.service" \
  || fail 'service does not run the installed script'
grep -q 'pr-gate-grype-db-refresh.timer' "$script_dir/pr-gate-install.sh" || fail 'installer does not enable the timer'
grep -q 'bin/pr-gate-\*\.sh\|/pr-gate-\[A-Za-z0-9._-\]+\\.sh' "$script_dir/pr-gate-install.sh" || fail 'installer does not install every bin/pr-gate-*.sh script'
printf 'PASS units and installer wiring\n'
