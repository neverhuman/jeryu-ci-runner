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
if [[ "\$*" == *list-units* ]]; then
  [[ ! -e "$fx/enum-fails" ]] || exit 2
  [[ ! -e "$fx/enum-empty" ]] || exit 0
  printf 'pr-gate-runner@0.timer loaded active waiting x\npr-gate-runner@1.timer loaded active waiting x\npr-gate-main-health@jeryu.timer loaded active waiting x\npr-gate-wake.timer loaded active waiting x\npr-gate-audit.timer loaded active waiting x\n'; fi
if [[ "\$*" == '--user stop pr-gate-runner@1.timer' && -e "$fx/stop-fails" ]]; then exit 2; fi
if [[ "\$*" == '--user start pr-gate-wake.timer' && -e "$fx/resume-fails" ]]; then exit 2; fi
exit 0
SH
cat >"$fx/stub/pgrep" <<SH
#!/usr/bin/env bash
printf 'pgrep %s\n' "\$*" >>"$fx/calls.log"
[[ ! -e "$fx/pgrep-fails" ]] || exit 2
if [[ -e "$fx/dispatch-busy" && "\$*" == *wake* && "\$*" == *audit* ]]; then exit 0; fi
[[ -e "$fx/busy" ]]
SH
cat >"$fx/stub/fixture-update" <<SH
#!/usr/bin/env bash
printf 'update ran %s\n' "\$*" >>"$fx/calls.log"
[[ ! -e "$fx/term-parent" ]] || kill -TERM "\$FIXTURE_UPDATE_PARENT"
[[ ! -e "$fx/update-slow" ]] || sleep 3
if [[ -e "$fx/update-stubborn" ]]; then
  trap '' TERM
  printf '%s\n' "\$BASHPID" >"$fx/stubborn-pid"
  sleep 30 &
  printf '%s\n' "\$!" >"$fx/stubborn-child"
  wait
fi
[[ ! -e "$fx/update-fails" ]] || exit 4
exit 0
SH
chmod +x "$fx/stub/systemctl" "$fx/stub/pgrep" "$fx/stub/fixture-update"
state="$fx/home/gate-runner/tool-update.json"
run() { : >"$fx/calls.log"; status=0
  local -a update_environment=("GATE_INSTALL_UPDATE_SECONDS=${update_seconds:-30}")
  [[ "${site_bound:-0}" != 1 ]] || update_environment=(-u GATE_INSTALL_UPDATE_SECONDS)
  HOME="$fx/home" PATH="$fx/stub:$PATH" PR_GATE_CONFIG="$fx/pr-gate.env" \
    GATE_INSTALL_DRAIN_SECONDS="${drain:-30}" GATE_INSTALL_LOCK_WAIT="${lock_wait:-5}" \
    env "${update_environment[@]}" timeout --kill-after=3 20 bash -c 'export FIXTURE_UPDATE_PARENT=$$; exec bash "$@"' \
      fixture-updater "$updater" "$@" >"$fx/out" 2>&1 || status=$?; }
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

# A failed or empty enumeration cannot establish a drain. In particular a working systemctl
# with no active slots must never authorize an update while some unobserved gate may still run.
for flag in enum-empty enum-fails; do
  touch "$fx/$flag"
  run -- fixture-update
  must "$flag allowed an update" test "$status" == 75
  must "$flag ran the command" absent 'update ran'
  must "$flag stopped a timer" absent '--user stop '
  rm -f "$fx/$flag"
done
printf 'PASS failed or empty timer enumeration runs nothing and touches no timer\n'

# The ordinary case: both slot timers stopped, the host drained, the command run, the timers started.
run -- fixture-update --now
must 'the update did not run' test "$status" == 0
must 'slot 0 stopped' called 'stop pr-gate-runner@0.timer'
must 'slot 1 stopped' called 'stop pr-gate-runner@1.timer'
must 'slot 0 resumed' called 'start pr-gate-runner@0.timer'
must 'slot 1 resumed' called 'start pr-gate-runner@1.timer'
for timer in pr-gate-main-health@jeryu.timer pr-gate-wake.timer pr-gate-audit.timer; do
  must "$timer stopped" called "stop $timer"
  must "$timer resumed" called "start $timer"
  must "update preceded $timer pause" test "$(at 'update ran')" -gt "$(at "stop $timer")"
done
must 'only active timers requested' grep -q -- '--state=active' "$fx/calls.log"
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

# A bounded update stops a command that would otherwise complete later, records the timeout,
# and restores every timer before returning. The outer fixture timeout bounds regressions too.
touch "$fx/update-slow"
update_seconds=1 run -- fixture-update
must 'the update command was not bounded' test "$status" == 124
must 'the timeout is not recorded' jq -e '.exit_code == 124 and .update_timeout_seconds == 1
  and .resume_failures == []' "$state" >/dev/null
must 'a timed out update did not restore the timers' called 'start pr-gate-wake.timer'
rm -f "$fx/update-slow"
# The explicit command bound is independent of the drain deadline.
update_seconds=30 run --update-timeout=1 -- fixture-update
must 'explicit update timeout was ignored' jq -e '.update_timeout_seconds == 1' "$state" >/dev/null
run --update-timeout=0 -- fixture-update
must 'zero disables the command bound' test "$status" == 2
must 'invalid command bound touched a timer' test ! -s "$fx/calls.log"
printf 'GATE_INSTALL_UPDATE_SECONDS=1\n' >>"$fx/pr-gate.env"
site_bound=1 run -- fixture-update
must 'site file command bound ignored' jq -e '.update_timeout_seconds == 1' "$state" >/dev/null
sed -i '$d' "$fx/pr-gate.env"
printf 'PASS updater execution has an independent positive timeout and restores timers\n'

# KILL grace also bounds a command and child that both ignore TERM. Ensure the group is no
# longer executing, rather than accepting the wrapper exiting while the tool keeps writing.
touch "$fx/update-stubborn"
update_seconds=1 run -- fixture-update
must 'TERM-ignoring update escaped the bound' test "$status" == 137
for pid_file in stubborn-pid stubborn-child; do
  pid=$(cat "$fx/$pid_file")
  if [[ -r "/proc/$pid/stat" ]]; then
    proc_state=$(awk '{print $3}' "/proc/$pid/stat")
    must 'a timed out update process is still executing' test "$proc_state" == Z
  fi
done
must 'KILL timeout not recorded' jq -e '.exit_code == 137 and .resume_failures == []' "$state" >/dev/null
must 'KILL timeout did not restore timers' called 'start pr-gate-runner@0.timer'
rm -f "$fx/update-stubborn"
printf 'PASS KILL grace stops the whole update process group before restoring timers\n'

# Restoration failures are observable and make a successful command invocation fail.
touch "$fx/resume-fails"
run -- fixture-update
must 'timer restore failure was hidden' test "$status" == 1
must 'timer restore failure absent from receipt' jq -e '.exit_code == 0
  and .resume_failures == ["pr-gate-wake.timer"]' "$state" >/dev/null
must 'a previously inactive timer was started' absent 'start pr-gate-runner@9.timer'
rm -f "$fx/resume-fails"
printf 'PASS failed restoration is recorded and no inactive timer is started\n'

# A TERM during the command still restores every scheduled entry point, and cannot claim
# completion of an interrupted update by overwriting the last finished receipt.
cp "$state" "$fx/before-term.json"
touch "$fx/term-parent"
run -- fixture-update
must 'TERM was hidden' test "$status" == 143
for timer in pr-gate-runner@0.timer pr-gate-main-health@jeryu.timer pr-gate-wake.timer pr-gate-audit.timer; do
  must "$timer not resumed after TERM" called "start $timer"
done
must 'TERM rewrote finished receipt' cmp -s "$state" "$fx/before-term.json"
rm -f "$fx/term-parent"
printf 'PASS TERM restores all scheduled gate sources and leaves finished receipt intact\n'

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

# A dispatcher already running when its timer stops can still launch a gate. A drain must
# wait for wake and audit as well, even with no runner process currently visible.
touch "$fx/dispatch-busy"
drain=0 run -- fixture-update
must 'an in-flight dispatcher was treated as drained' test "$status" == 75
must 'an update raced the active dispatcher' absent 'update ran'
must 'the dispatcher timeout lost timer restoration' called 'start pr-gate-wake.timer'
rm -f "$fx/dispatch-busy"
printf 'PASS active wake and audit dispatchers must drain before the update\n'

# Failed process inspection and partial timer-stop failures are not a successful drain.
for flag in pgrep-fails stop-fails; do
  touch "$fx/$flag"
  run -- fixture-update
  must "$flag was accepted" test "$status" != 0
  must "$flag ran an update" absent 'update ran'
  must "$flag lost restoration" called 'start pr-gate-runner@0.timer'
  must "$flag rewrote the completed receipt" cmp -s "$fx/before.json" "$state"
  rm -f "$fx/$flag"
done
printf 'PASS failed gate inspection and partial stops never run an update and restore timers\n'

# An install holds the same lock: the update waits for it, then gives up without touching a timer.
flock -w 5 "$fx/home/gate-runner/.install.lock" -c "PATH='$fx/stub:$PATH' HOME='$fx/home' \
  PR_GATE_CONFIG='$fx/pr-gate.env' GATE_INSTALL_LOCK_WAIT=1 bash '$updater' -- fixture-update >'$fx/out' 2>&1; echo \$? >'$fx/status'" \
  || { printf 'FAIL: could not take the install lock\n' >&2; exit 1; }
must 'an update ran during an install' test "$(cat "$fx/status")" == 75
must 'the install is named' grep -q 'an install is running; nothing updated' "$fx/out"
must 'a locked-out update left no record of itself' cmp -s "$fx/before.json" "$state"
printf 'PASS an update never overlaps an install\n'

printf 'pr-gate-tool-update: all checks passed\n'
