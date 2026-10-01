#!/usr/bin/env bash
# Exercise the production supervisor command with real locks and processes.
set -euo pipefail
# A gate may run this suite inside a pr-gate-runner whose environment reaches the recipe. Its
# GATE_RUNNER_*/JERYU_*/PR_GATE_* variables would then steer the code under test. Start clean.
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
fixture=$(mktemp -d)
parent="" supervisor="" worker="" daemon=""
cleanup() {
  for pid in "$daemon" "$worker" "$supervisor" "$parent"; do
    [[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true
  done
  rm -rf -- "$fixture"
}
trap cleanup EXIT
# Use the actual launch line, so descriptor regressions in production fail here.
launch=$(sed -n '/^[[:space:]]*timeout --kill-after=30s 3h /p' "$script_dir/pr-gate-runner.sh")
[[ -n "$launch" && "$(printf '%s\n' "$launch" | wc -l)" == 1 ]]
cat >"$fixture/worker.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
fixture=$1
for fd in 6 7 9; do [[ ! -e "/proc/$$/fd/$fd" ]]; done
printf '%s\n' "$$" >"$fixture/worker"
printf '%s\n' "$PPID" >"$fixture/supervisor"
if [[ "$2" == daemon ]]; then
  sleep 30 </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" >"$fixture/daemon"
else
  while [[ ! -f "$fixture/release" ]]; do sleep 0.02; done
fi
SH
cat >"$fixture/parent.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
fixture=$1 mode=$2
exec 6>"$fixture/head.lock" 7>"$fixture/repo.lock" 9>"$fixture/slot.lock"
flock -n 6; flock -n 7; flock -n 9
recipe=(bash "$fixture/worker.sh" "$fixture" "$mode")
SH
printf '%s\n' "$launch &" 'wait "$!"' >>"$fixture/parent.sh"
wait_file() {
  for _ in $(seq 1 250); do [[ ! -s "$1" ]] || return 0; sleep 0.02; done
  printf 'Timed out waiting for %s\n' "$1" >&2
  return 1
}
available() { flock -n "$fixture/$1.lock" true; }
wait_release() {
  for _ in $(seq 1 250); do
    if available head && available repo && available slot; then return 0; fi
    sleep 0.02
  done
  return 1
}
bash "$fixture/parent.sh" "$fixture" block &
parent=$!
wait_file "$fixture/worker"
wait_file "$fixture/supervisor"
worker=$(cat "$fixture/worker") supervisor=$(cat "$fixture/supervisor")
for fd in 6 7 9; do [[ -e "/proc/$supervisor/fd/$fd" ]]; done
for key in head repo slot; do if available "$key"; then exit 1; fi; done
kill -KILL "$parent"
wait "$parent" 2>/dev/null || true
parent=""
kill -0 "$worker"
for key in head repo slot; do if available "$key"; then exit 1; fi; done
touch "$fixture/release"
wait_release
worker="" supervisor=""
printf 'PASS parent death: head, shared target and slot source locks survive until worker exit\n'

rm -f "$fixture/worker" "$fixture/supervisor"
bash "$fixture/parent.sh" "$fixture" daemon &
parent=$!
wait_file "$fixture/daemon"
daemon=$(cat "$fixture/daemon")
wait "$parent"
parent=""
kill -0 "$daemon"
wait_release
for fd in 6 7 9; do [[ ! -e "/proc/$daemon/fd/$fd" ]]; done
printf 'PASS successful completion: a live cache daemon retains none of the three locks\n'
