#!/usr/bin/env bash
# Exercise pr-gate-tool-update.sh: a host tool update runs only while the slots are drained, the
# timers come back whatever the update did, and nothing runs when the host will not drain.
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
updater="$script_dir/pr-gate-tool-update.sh"
fx=$(mktemp -d)
trap 'rm -rf -- "$fx"' EXIT
mkdir -p "$fx/stub" "$fx/home/gate-runner/bin"
printf 'PR_GATE_CODE_REPO=example/gate-code\n' >"$fx/pr-gate.env"

# systemctl and pgrep stubs: the timer calls are recorded, and the host is "busy" while $fx/busy
# exists. The update command records, in the same log, that it ran -- so the order is an assertion.
cat >"$fx/stub/systemctl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$fx/calls.log"
if [[ "\$*" == *list-units* ]]; then printf 'pr-gate-runner@0.timer loaded active waiting x\npr-gate-runner@1.timer loaded active waiting x\n'; fi
exit 0
SH
cat >"$fx/stub/pgrep" <<SH
#!/usr/bin/env bash
printf 'pgrep %s\n' "\$*" >>"$fx/calls.log"
[[ -e "$fx/busy" ]]
SH
cat >"$fx/stub/fixture-update" <<SH
#!/usr/bin/env bash
printf 'update ran %s\n' "\$*" >>"$fx/calls.log"
[[ ! -e "$fx/update-fails" ]] || exit 4
exit 0
SH
chmod +x "$fx/stub/systemctl" "$fx/stub/pgrep" "$fx/stub/fixture-update"
state="$fx/home/gate-runner/tool-update.json"
run() { : >"$fx/calls.log"; status=0
  HOME="$fx/home" PATH="$fx/stub:$PATH" PR_GATE_CONFIG="$fx/pr-gate.env" \
    GATE_INSTALL_DRAIN_SECONDS="${drain:-30}" GATE_INSTALL_LOCK_WAIT="${lock_wait:-5}" \
    bash "$updater" "$@" >"$fx/out" 2>&1 || status=$?; }
must() { local why=$1; shift; "$@" || { printf 'FAIL: %s\n' "$why" >&2; cat "$fx/out" "$fx/calls.log" >&2 2>/dev/null; exit 1; }; }
called() { grep -qx -- "--user $1" "$fx/calls.log"; }
absent() { ! grep -q -- "$1" "$fx/calls.log"; }
# The line number of the first log line matching a pattern.
at() { grep -n -- "$1" "$fx/calls.log" | head -1 | cut -d: -f1; }

# No command, or a command that does not exist: nothing is stopped and nothing runs.
run
must 'an empty invocation was accepted' test "$status" == 2
must 'usage printed' grep -q 'usage: pr-gate-tool-update.sh' "$fx/out"
must 'no timer touched without a command' test ! -s "$fx/calls.log"
run -- /nonexistent/tool update
must 'a missing command was accepted' test "$status" == 2
must 'the missing command is named' grep -q 'no such command: /nonexistent/tool' "$fx/out"
must 'no timer touched for a missing command' test ! -s "$fx/calls.log"
run --timeout notanumber -- fixture-update
must 'a non-numeric timeout was accepted' test "$status" == 2
printf 'PASS nothing is drained without a usable update command\n'

# The ordinary case: both slot timers stopped, the host drained, the command run, the timers started.
run -- fixture-update --now
must 'the update did not run' test "$status" == 0
must 'slot 0 stopped' called 'stop pr-gate-runner@0.timer'
must 'slot 1 stopped' called 'stop pr-gate-runner@1.timer'
must 'slot 0 resumed' called 'start pr-gate-runner@0.timer'
must 'slot 1 resumed' called 'start pr-gate-runner@1.timer'
must 'the update ran before the slots were stopped' test "$(at 'update ran')" -gt "$(at 'stop pr-gate-runner@0.timer')"
must 'the update ran before the host was checked for running gates' test "$(at 'update ran')" -gt "$(at '^pgrep ')"
must 'the slots resumed before the update finished' test "$(at 'start pr-gate-runner@0.timer')" -gt "$(at 'update ran')"
must 'the command is not recorded' jq -e '.command == ["fixture-update","--now"] and .exit_code == 0
  and (.finished_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and .drained_slots == ["0","1"]' "$state" >/dev/null
printf 'PASS an update runs between stopping and resuming the slot timers, and is recorded with its status\n'

# A failing update is reported as it exited, and the slots still come back.
touch "$fx/update-fails"
run -- fixture-update
must 'a failing update was reported green' test "$status" == 4
must 'slot 1 resumed after a failure' called 'start pr-gate-runner@1.timer'
must 'the failure is recorded' jq -e '.exit_code == 4' "$state" >/dev/null
rm -f "$fx/update-fails"
printf 'PASS a failing update keeps its status and still resumes the slots\n'

# A host that will not drain updates nothing: the record of the last update is left as it was.
cp "$state" "$fx/before.json"
touch "$fx/busy"
drain=0 run -- fixture-update
must 'a busy host was updated' test "$status" == 75
must 'the busy host is named' grep -q 'slots still busy after 0s; nothing updated' "$fx/out"
must 'the update ran on a busy host' absent 'update ran'
must 'the slots did not resume on a busy host' called 'start pr-gate-runner@0.timer'
must 'a busy host rewrote the record' cmp -s "$fx/before.json" "$state"
rm -f "$fx/busy"
printf 'PASS a host that does not drain in time updates nothing, and its slots still resume\n'

# An install holds the same lock: the update waits for it, then gives up without touching a timer.
flock -w 5 "$fx/home/gate-runner/.install.lock" -c "PATH='$fx/stub:$PATH' HOME='$fx/home' \
  PR_GATE_CONFIG='$fx/pr-gate.env' GATE_INSTALL_LOCK_WAIT=1 bash '$updater' -- fixture-update >'$fx/out' 2>&1; echo \$? >'$fx/status'" \
  || { printf 'FAIL: could not take the install lock\n' >&2; exit 1; }
must 'an update ran during an install' test "$(cat "$fx/status")" == 75
must 'the install is named' grep -q 'an install is running; nothing updated' "$fx/out"
must 'a locked-out update left no record of itself' cmp -s "$fx/before.json" "$state"
printf 'PASS an update never overlaps an install\n'

printf 'pr-gate-tool-update: all checks passed\n'
