#!/usr/bin/env bash
# Exercise pr-gate-backoff.sh: exponential growth, the cap, Retry-After, and clearing.
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/pr-gate-backoff.sh"
fx=$(mktemp -d)
trap 'rm -rf -- "$fx"' EXIT
HOME_DIR="$fx/home"
# shellcheck source=ops/pr-gate/bin/pr-gate-backoff.sh
source "$lib"
must() { local why=$1; shift; "$@" || { printf 'FAIL: %s\n' "$why" >&2; exit 1; }; }
delay() { echo $(( $(cut -d' ' -f1 "$BACKOFF_FILE") - $(date +%s) )); }

must 'clear to begin with' test "$(backoff_remaining)" == 0
: >"$fx/none"
backoff_note_429 "$fx/none"; d1=$(delay)
backoff_note_429 "$fx/none"; d2=$(delay)
backoff_note_429 "$fx/none"; d3=$(delay)
must 'first wait is the base' test "$d1" -ge 28 -a "$d1" -le 30
must 'it doubles' test "$d2" -ge 58 -a "$d2" -le 60
must 'and doubles again' test "$d3" -ge 118 -a "$d3" -le 120
must 'remaining reports the wait' test "$(backoff_remaining)" -ge 118
for _ in $(seq 12); do backoff_note_429 "$fx/none"; done
must 'the wait is capped' test "$(delay)" -le "$BACKOFF_CAP"
backoff_clear
must 'success clears it' test "$(backoff_remaining)" == 0
printf 'PASS the back-off doubles per 429, is capped, and clears\n'

printf 'HTTP/1.1 429\r\nretry-after: 200\r\n\r\n' >"$fx/ra"
backoff_note_429 "$fx/ra"
must 'Retry-After longer than the next step is honoured' test "$(delay)" -ge 195
backoff_clear
printf 'Retry-After: 5\r\n' >"$fx/ra"
backoff_note_429 "$fx/ra"
must 'a short Retry-After does not undercut the exponential floor' test "$(delay)" -ge 28
backoff_clear
printf 'Retry-After: 999999\r\n' >"$fx/ra"
backoff_note_429 "$fx/ra"
must 'an absurd Retry-After is capped' test "$(delay)" -le "$BACKOFF_CAP"
printf 'PASS Retry-After is honoured within the cap\n'
