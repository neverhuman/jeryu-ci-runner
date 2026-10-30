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
#   2. pause active slot, main-health, wake and audit timers and wait until no runner process is left (at most
#      GATE_INSTALL_DRAIN_SECONDS, default 45 minutes; else nothing is updated);
#   3. run the update command given on the command line, once, with this script's environment;
#   4. restore the previously active timers, whatever the command did, and record the outcome in
#      tool-update.json.
#
# Usage, from the gate user's own timer or by hand -- the command after `--` is run verbatim,
# never through a shell:
#
#   pr-gate-tool-update.sh [--timeout SECONDS] -- claude update
#
# Exit status: the command's, or 75 (nothing was run: an install holds the lock, or the slots did not
# drain in time) so a timer can simply try again later. It never gates, approves, merges or touches a
# gate's evidence; the one thing it changes is what the host has installed.
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
STATE="$HOME_DIR/tool-update.json"
LOCK_WAIT="${GATE_INSTALL_LOCK_WAIT:-60}"

say() { printf '[gate-tool-update %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
usage() { printf 'usage: %s [--timeout SECONDS] -- COMMAND [ARG...]\n' "$(basename -- "$0")" >&2; exit 2; }

while (($#)); do
  case "$1" in
    --timeout) [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]] || usage; DRAIN_SECONDS=$2; shift 2;;
    --timeout=*) [[ "${1#--timeout=}" =~ ^[0-9]+$ ]] || usage; DRAIN_SECONDS=${1#--timeout=}; shift;;
    --) shift; break;;
    *) usage;;
  esac
done
(($# > 0)) || usage
[[ "$DRAIN_SECONDS" =~ ^[0-9]+$ ]] || { say "GATE_INSTALL_DRAIN_SECONDS must be a number of seconds, not $DRAIN_SECONDS"; exit 2; }
command -v -- "$1" >/dev/null || { say "no such command: $1"; exit 2; }

mkdir -p "$HOME_DIR"
# The installer's lock: it drains the same slots, and the two must not interleave. Waiting a little
# covers an install that is merely verifying; a long one simply means later is better.
exec 9>"$HOME_DIR/.install.lock"
flock -w "$LOCK_WAIT" 9 || { say "an install is running; nothing updated"; exit 75; }

# Pause every scheduled source of gates, including wake when it has explicitly configured
# slots. Restore only the timers that were active; an operator's paused timer stays paused.
timers=$(systemctl --user list-units --no-legend --plain --state=active \
  'pr-gate-runner@*.timer' 'pr-gate-main-health@*.timer' pr-gate-wake.timer pr-gate-audit.timer \
  | sed -n '/^pr-gate-\(runner@[0-9]\+\|main-health@[^ ]\+\|wake\|audit\)\.timer /s/ .*//p' | sort -u)
slots=$(printf '%s\n' "$timers" | sed -n 's/^pr-gate-runner@\([0-9]\+\)\.timer$/\1/p' | sort -un | tr '\n' ' ')
resume() { local timer; for timer in $timers; do systemctl --user start "$timer" || true; done; }
trap resume EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for timer in $timers; do systemctl --user stop "$timer"; done
deadline=$(( $(date +%s) + DRAIN_SECONDS ))
while pgrep -f "$BIN/pr-gate-runner.sh" >/dev/null; do
  if (( $(date +%s) >= deadline )); then
    say "slots still busy after ${DRAIN_SECONDS}s; nothing updated, run it again later"
    exit 75
  fi
  sleep 10
done
say "slots drained (${slots:-none}); running: $*"

status=0
"$@" || status=$?

# Recorded only now, with what actually happened: a crash before this leaves no claim that the tool
# was updated, and the next run simply drains and tries again. One record, never a growing log.
jq -n --arg at "$(date -u +%FT%TZ)" --argjson status "$status" \
  --argjson command "$(printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]')" \
  --arg slots "${slots% }" \
  '{command:$command,exit_code:$status,finished_at:$at,drained_slots:($slots|split(" ")|map(select(. != "")))}' \
  >"$STATE.new.$$" && mv -f -- "$STATE.new.$$" "$STATE" || say "could not record the update in $STATE"
say "update exited $status"
exit "$status"
