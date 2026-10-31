#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pr-gate-tool-update.sh — update a tool on the gate host inside a gate drain.
#
# The recipe PATH and its tools are bound into a gate's input identity, and the
# identity is computed again when the recipe finishes: a tool replaced while a gate ran ends that
# attempt as "inputs_changed" however green its recipe was (jeryu-ci-runner#165 attempt 5538ab4e,
# 2026-10-30: a full required/proof pass at score 94 discarded because an agent tool under
# ~/.local/bin had updated itself meanwhile). Freezing the inputs is not the answer -- a result must
# never be published for bytes that changed during execution -- so an update waits for the gates
# instead, exactly as installing a new runner does:
#
#   1. take the installer's lock, so an install and a tool update never overlap;
#   2. pause active slot, main-health, wake and audit timers and wait until no runner or
#      dispatcher is left (GATE_INSTALL_DRAIN_SECONDS, default 45 minutes; else nothing updated);
#   3. run the update command once, bounded by GATE_INSTALL_UPDATE_SECONDS (default 10 minutes);
#   4. restore the previously active timers, whatever the command did, and record the outcome in
#      tool-update.json.
#
# Usage, from the gate user's own timer or by hand -- the command after `--` is run verbatim,
# never through a shell:
#
#   pr-gate-tool-update.sh [--timeout SECONDS] [--update-timeout SECONDS] -- claude update
#
# Exit status: the command's, or 75 (nothing was run: an install holds the lock, or the slots did not
# drain in time) so a timer can simply try again later. It never gates, approves, merges or touches a
# gate's evidence; the one thing it changes is what the host has installed.
# timeout returns 124, or 137 if TERM requires KILL after another 10 seconds. A failed timer
# restoration makes an otherwise successful invocation fail and is named in the receipt.
# A command can itself exit 75: tool-update.json records whether it actually ran.
# SIGKILL or host loss cannot run the EXIT trap; operators must restore paused timers after that.
#
# The alternative, for a tool that cannot be told when to update, is to keep it off the recipe's PATH
# and put the version the gate uses in a directory the gate owns (PR_GATE_RECIPE_PATH, README.md
# "Results across hosts").
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=ops/pr-gate/bin/pr-gate-config.sh
source "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/pr-gate-config.sh"
pr_gate_load_config
HOME_DIR="${GATE_RUNNER_HOME:-$HOME/gate-runner}"
BIN="${GATE_INSTALL_BIN:-$HOME_DIR/bin}"
DRAIN_SECONDS="${GATE_INSTALL_DRAIN_SECONDS:-2700}"
UPDATE_SECONDS="${GATE_INSTALL_UPDATE_SECONDS:-600}"
STATE="$HOME_DIR/tool-update.json"
LOCK_WAIT="${GATE_INSTALL_LOCK_WAIT:-60}"

say() { printf '[gate-tool-update %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
usage() { printf 'usage: %s [--timeout SECONDS] [--update-timeout SECONDS] -- COMMAND [ARG...]\n' "$(basename -- "$0")" >&2; exit 2; }

while (($#)); do
  case "$1" in
    --timeout) [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]] || usage; DRAIN_SECONDS=$2; shift 2;;
    --timeout=*) [[ "${1#--timeout=}" =~ ^[0-9]+$ ]] || usage; DRAIN_SECONDS=${1#--timeout=}; shift;;
    --update-timeout) [[ -n "${2:-}" && "$2" =~ ^[1-9][0-9]*$ ]] || usage; UPDATE_SECONDS=$2; shift 2;;
    --update-timeout=*) [[ "${1#--update-timeout=}" =~ ^[1-9][0-9]*$ ]] || usage; UPDATE_SECONDS=${1#--update-timeout=}; shift;;
    --) shift; break;;
    *) usage;;
  esac
done
(($# > 0)) || usage
[[ "$DRAIN_SECONDS" =~ ^[0-9]+$ ]] || { say "GATE_INSTALL_DRAIN_SECONDS must be a number of seconds, not $DRAIN_SECONDS"; exit 2; }
[[ "$UPDATE_SECONDS" =~ ^[1-9][0-9]*$ ]] || { say "GATE_INSTALL_UPDATE_SECONDS must be positive seconds"; exit 2; }
command -v timeout >/dev/null || { say "timeout is required; nothing updated"; exit 2; }
command -v -- "$1" >/dev/null || { say "no such command: $1"; exit 2; }

mkdir -p "$HOME_DIR"
# The installer's lock: it drains the same slots, and the two must not interleave. Waiting a little
# covers an install that is merely verifying; a long one simply means later is better.
exec 9>"$HOME_DIR/.install.lock"
flock -w "$LOCK_WAIT" 9 || { say "an install is running; nothing updated"; exit 75; }

# Pause every scheduled source of gates, including wake when it has explicitly configured
# slots. Restore only the timers that were active; an operator's paused timer stays paused.
timer_units=$(systemctl --user list-units --no-legend --plain --state=active \
  'pr-gate-runner@*.timer' 'pr-gate-main-health@*.timer' pr-gate-wake.timer pr-gate-audit.timer) \
  || { say "could not enumerate active gate timers; nothing updated"; exit 75; }
timers=$(printf '%s\n' "$timer_units" \
  | sed -n '/^pr-gate-\(runner@[0-9]\+\|main-health@[^ ]\+\|wake\|audit\)\.timer /s/ .*//p' | sort -u)
slots=$(printf '%s\n' "$timers" | sed -n 's/^pr-gate-runner@\([0-9]\+\)\.timer$/\1/p' | sort -un | tr '\n' ' ')
[[ -n "$slots" ]] || { say "no active gate slots were enumerated; nothing updated"; exit 75; }
command_args=("$@")
command_finished=0 status=0 update_pid=""
finish() {
  local result=${1:-$?} timer
  local resume_failures=()
  trap - EXIT
  stop_update
  for timer in $timers; do
    if ! systemctl --user start "$timer"; then
      say "could not restore $timer"
      resume_failures+=("$timer")
    fi
  done
  if ((command_finished)); then
    if ! jq -n --arg at "$(date -u +%FT%TZ)" --argjson status "$status" \
      --argjson command "$(jq -nc --args '$ARGS.positional' -- "${command_args[@]}")" \
      --argjson limit "$UPDATE_SECONDS" --arg slots "${slots% }" \
      --argjson failed "$(jq -nc --args '$ARGS.positional' -- "${resume_failures[@]}")" \
      '{command:$command,exit_code:$status,finished_at:$at,update_timeout_seconds:$limit,
        drained_slots:($slots|split(" ")|map(select(. != ""))),resume_failures:$failed}' \
      >"$STATE.new.$$" || ! mv -f -- "$STATE.new.$$" "$STATE"; then
      say "could not record the update in $STATE"
      ((result != 0)) || result=1
    fi
  fi
  if ((${#resume_failures[@]} > 0 && result == 0)); then result=1; fi
  exit "$result"
}
stop_update() {
  trap - INT TERM
  if [[ -n "$update_pid" ]]; then
    # GNU timeout forwards TERM to the command group and enforces its KILL grace.
    kill -TERM "$update_pid" 2>/dev/null || true
    wait "$update_pid" 2>/dev/null || true
    update_pid=""
  fi
}
trap 'finish' EXIT
trap 'stop_update; exit 130' INT
trap 'stop_update; exit 143' TERM
for timer in $timers; do systemctl --user stop "$timer"; done
deadline=$(( $(date +%s) + DRAIN_SECONDS ))
# A wake or audit service already running when its timer was paused may still dispatch a gate.
# Let it finish too, before accepting an empty runner set as a drain.
while :; do
  busy=0
  pgrep -f "$BIN/pr-gate-(runner|wake|audit)\.sh" >/dev/null || busy=$?
  if ((busy == 1)); then break; fi
  if ((busy != 0)); then say "could not inspect running gates; nothing updated"; exit 75; fi
  if (( $(date +%s) >= deadline )); then
    say "slots still busy after ${DRAIN_SECONDS}s; nothing updated, run it again later"
    exit 75
  fi
  sleep 10
done
say "slots drained ($slots); running: $*"

# A process group gives timeout authority over the update and its children. Waiting for it on
# INT/TERM keeps timers paused until the command group has stopped; no finished receipt is written
# for an interrupted invocation. SIGKILL/host loss still requires the documented manual recovery.
timeout --kill-after=10 "$UPDATE_SECONDS" "$@" <&0 &
update_pid=$!
wait "$update_pid" || status=$?
update_pid=""
command_finished=1
say "update exited $status"
finish "$status"
