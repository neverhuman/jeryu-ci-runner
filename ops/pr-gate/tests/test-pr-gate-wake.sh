#!/usr/bin/env bash
# Exercise pr-gate-wake.sh against a fixture forge and a slot-control shim that records what it
# starts: first the fallback that reads gated heads (a forge with no wake-up signal), then the signal.
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
wake="$script_dir/pr-gate-wake.sh"
fx=$(mktemp -d)
trap 'rm -rf -- "$fx"' EXIT
mkdir -p "$fx/bin" "$fx/home/cache" "$fx/forge"
printf 'WAKE-TOKEN-7f3a\n' >"$fx/token"; chmod 0600 "$fx/token"
printf 'acme/acme-a\ngate-a/gate-b\n' >"$fx/home/cache/protected-acme"
printf 'PR_GATE_FORGE_URL=https://forge.example.test\nGATE_RUNNER_OWNERS=acme\n' >"$fx/pr-gate.env"

# The fixture forge serves $fx/forge/<name>.json; a missing file answers 500.
cat >"$fx/bin/curl" <<SH
#!/usr/bin/env bash
[[ "\$*" != *WAKE-TOKEN-7f3a* ]] || exit 9
url="\${@: -1}"
printf '%s\n' "\$url" >>"$fx/curl.log"
case "\$url" in
  */repos/acme%2Facme-a/pulls*) f=a;;
  */repos/gate-a%2Fgate-b/pulls*) f=b;;
  */merge-queue*) f=queue;;
  */gate-regate*) f=regate;;
  */gate-wanted*) f=wanted;;
  *) f=none;;
esac
if [[ -e "$fx/forge/\$f.json" ]]; then printf '%s\n200' "\$(cat "$fx/forge/\$f.json")"; else printf 'oops\n500'; fi
SH
# Slots 0..2 have active timers; a slot is busy when $fx/busy-N exists.
cat >"$fx/bin/systemctl" <<SH
#!/usr/bin/env bash
case "\$*" in
  *list-units*) printf 'pr-gate-runner@0.timer loaded active waiting x\npr-gate-runner@1.timer loaded active waiting x\npr-gate-runner@2.timer loaded active waiting x\n';;
  *is-active*) n=\${3#pr-gate-runner@}; n=\${n%.service}; if [[ -e "$fx/busy-\$n" ]]; then echo active; else echo inactive; exit 3; fi;;
  *start*) printf '%s\n' "\$*" >>"$fx/started.log";;
esac
SH
chmod +x "$fx/bin/curl" "$fx/bin/systemctl"
pulls() { local f=$1; shift; printf '{"items":[%s]}' "$(IFS=,; echo "$*")" >"$fx/forge/$f.json"; }
pr() { printf '{"number":%s,"head_sha":"%s"}' "$1" "$2"; }
run() { : >"$fx/started.log"; HOME="$fx/home" PATH="$fx/bin:$PATH" GATE_RUNNER_HOME="$fx/home" JERYU_TOKEN_FILE="$fx/token" \
  PR_GATE_CONFIG="$fx/pr-gate.env" bash "$wake" >"$fx/out"; }
must() { local why=$1; shift; "$@" || { printf 'FAIL: %s\n' "$why" >&2; cat "$fx/out" "$fx/started.log" >&2; exit 1; }; }
started() { grep -c . "$fx/started.log" || true; }
A1=$(printf 'a%.0s' {1..40}) A2=$(printf 'c%.0s' {1..40}) B1=$(printf 'b%.0s' {1..40}) Q1=$(printf 'd%.0s' {1..40})

pulls a "$(pr 1 "$A1")"; pulls b; printf '{"entries":[]}' >"$fx/forge/queue.json"
run
must 'first poll records and wakes nothing' test "$(started)" == 0
must 'view recorded' grep -qx "acme/acme-a 1 $A1" "$fx/home/cache/wake-heads"
must 'the fallback says why it read heads' grep -q 'no gate-wanted signal' "$fx/out"
must 'no sequence is kept without the signal' test ! -e "$fx/home/cache/wake-seq"
must 'token never reaches argv' test "$(grep -c WAKE-TOKEN-7f3a "$fx/curl.log" || true)" == 0
run
must 'unchanged view wakes nothing' test "$(started)" == 0
printf 'PASS first poll and unchanged heads wake nothing\n'

pulls a "$(pr 1 "$A2")"
run
must 'moved head wakes exactly one slot' test "$(started)" == 1
must 'the lowest idle slot' grep -qx -- '--user start --no-block pr-gate-runner@0.service' "$fx/started.log"
printf 'PASS a moved head wakes one idle slot\n'

touch "$fx/busy-0"
pulls b "$(pr 7 "$B1")"
printf '{"entries":[{"repo":"acme/acme-a","number":1,"queue_sha":"%s","queue_ref":"refs/queue/main/1"}]}' "$Q1" >"$fx/forge/queue.json"
run
must 'two new heads wake two idle slots' test "$(started)" == 2
must 'busy slot skipped' test "$(grep -c 'runner@0' "$fx/started.log" || true)" == 0
printf 'PASS new PR and queue entry wake one idle slot each, skipping busy ones\n'

# A re-gate asked for on the forge is work an idle slot can start now, and asking again for the same
# head is a new ask, because the runner decides whether it still owes it.
printf '{"requests":[{"repo":"acme/acme-a","number":1,"head_sha":"%s","requested_at":"2026-10-04T09:00:00Z"}]}' "$A2" \
  >"$fx/forge/regate.json"
run
must 'a pending re-gate wakes one idle slot' test "$(started)" == 1
must 'the request is in the view' grep -qx "acme/acme-a 1 $A2 regate 2026-10-04T09:00:00Z" "$fx/home/cache/wake-heads"
run
must 'the same request wakes nothing again' test "$(started)" == 0
printf '{"requests":[{"repo":"acme/acme-a","number":1,"head_sha":"%s","requested_at":"2026-10-04T09:05:00Z"}]}' "$A2" \
  >"$fx/forge/regate.json"
run
must 'asking again wakes a slot again' test "$(started)" == 1
rm -f "$fx/forge/regate.json"
run
must 'a withdrawn request wakes nothing' test "$(started)" == 0
printf 'PASS a pending re-gate request wakes an idle slot, once per ask\n'

touch "$fx/busy-1" "$fx/busy-2"
pulls a "$(pr 1 "$A1")"
run
must 'no idle slot, nothing started' test "$(started)" == 0
must 'says so' grep -q 'none idle' "$fx/out"
rm -f "$fx"/busy-*
printf 'PASS all slots busy: nothing started, the timers pick it up\n'

rm "$fx/forge/b.json" "$fx/forge/queue.json"
run
must 'forge error wakes nothing' test "$(started)" == 0
must 'unreadable repo keeps its heads' grep -qx "gate-a/gate-b 7 $B1" "$fx/home/cache/wake-heads"
must 'unreadable queue keeps its entries' grep -q "$Q1 queue" "$fx/home/cache/wake-heads"
printf 'PASS forge errors neither wake nor forget\n'

pulls b "$(pr 7 "$B1")" "$(pr 8 "$A1")"; printf '{"entries":[]}' >"$fx/forge/queue.json"
: >"$fx/home/cache/protected-acme"
run
must 'no repos known: nothing polled, nothing woken' test "$(started)" == 0
printf 'PASS without a discovery cache it stays quiet\n'

# The credential goes only to the configured forge, and an unconfigured host says so instead of guessing.
if JERYU_BASE=https://forge.example.test.foreign.invalid run 2>"$fx/err"; then
  printf 'FAIL: a foreign JERYU_BASE was accepted\n' >&2; exit 1; fi
must 'foreign origin refused' grep -q 'noncanonical credential origin' "$fx/err"
printf 'JERYU_TOKEN_FILE=%s\n' "$fx/token" >"$fx/no-forge.env"
if HOME="$fx/home" PATH="$fx/bin:$PATH" GATE_RUNNER_HOME="$fx/home" PR_GATE_CONFIG="$fx/no-forge.env" \
  bash "$wake" >"$fx/out" 2>"$fx/err"; then printf 'FAIL: wake ran without a configured forge\n' >&2; exit 1; fi
must 'missing forge named' grep -q 'PR_GATE_FORGE_URL is not configured' "$fx/err"
must 'nothing started' test "$(started)" == 0
printf 'PASS a foreign origin and an unconfigured forge are refused before any request\n'

# ---------------------------------------------------------------------------
# The forge's wake-up signal: one cheap long poll replaces the head reads above, and a signal the
# forge recorded on a push, a queue build or a re-gate starts an idle slot straight away.
# ---------------------------------------------------------------------------
rm -rf -- "$fx/home"; mkdir -p "$fx/home/cache"
printf 'acme/acme-a\ngate-a/gate-b\n' >"$fx/home/cache/protected-acme"
pulls a "$(pr 1 "$A1")"; pulls b; printf '{"entries":[]}' >"$fx/forge/queue.json"
signal() { # seq signal-json...
  local seq=$1; shift
  printf '{"seq":%s,"signals":[%s]}' "$seq" "$(IFS=,; echo "$*")" >"$fx/forge/wanted.json"
}
wanted() { # repo sha source
  printf '{"seq":1,"repo":"%s","sha":"%s","source":"%s","at":"2026-10-08T09:00:00Z"}' "$1" "$2" "$3"
}
seq_file() { cat "$fx/home/cache/wake-seq" 2>/dev/null || true; }

signal 4 "$(wanted acme/acme-a "$A1" push)"
: >"$fx/curl.log"
run
must 'first look records the sequence and wakes nothing' test "$(started)" == 0
must 'the sequence is the forge current one' test "$(seq_file)" == 4
must 'the first look does not wait' grep -q 'gate-wanted?after=0&wait=0' "$fx/curl.log"
must 'the open-PR view is recorded too' grep -qx "acme/acme-a 1 $A1" "$fx/home/cache/wake-heads"
printf 'PASS the first look records the sequence and the head view, and wakes nothing\n'

: >"$fx/curl.log"
signal 4
run
must 'the view is not read again within the period' test "$(grep -c '/pulls' "$fx/curl.log" || true)" == 0
must 'and nothing was woken' test "$(started)" == 0
: >"$fx/curl.log"
GATE_RUNNER_WAKE_HEADS_EVERY=0 run
must 'a period of 0 reads it every look' test "$(grep -c '/pulls' "$fx/curl.log" || true)" == 2
must 'an unchanged view still wakes nothing' test "$(started)" == 0
printf 'PASS with the signal working the open-PR view is read on a period, not on every look\n'

signal 6 "$(wanted acme/acme-a "$A2" push)" "$(wanted acme/acme-a "$Q1" queue)"
: >"$fx/curl.log"
run
must 'two signals wake two idle slots' test "$(started)" == 2
must 'the next look waits past the sequence it acted on' grep -q 'gate-wanted?after=4&wait=30' "$fx/curl.log"
must 'the sequence advanced' test "$(seq_file)" == 6
# What the forge answers once it has nothing above the sequence the runner asked past: the same
# sequence and no signals, so one signal buys exactly one tick.
signal 6
run
must 'nothing above the sequence wakes nothing again' test "$(started)" == 0
must 'and the sequence stands' test "$(seq_file)" == 6
printf 'PASS a push and a queue build each wake one idle slot, once\n'

# The forge hands over every repository the identity may read; only the ones this host gates are
# worth a slot, and the sequence still advances past the rest.
signal 9 "$(wanted other/elsewhere "$B1" push)"
run
must 'a signal for a repo this host does not gate wakes nothing' test "$(started)" == 0
must 'but its sequence is not read again' test "$(seq_file)" == 9
printf 'PASS a signal for an ungated repository is skipped, not re-read\n'

# A forge that restarted hands out a smaller sequence: that is a resync, not a backlog of work.
signal 2 "$(wanted acme/acme-a "$A1" push)"
run
must 'a restarted forge wakes nothing' test "$(started)" == 0
must 'and its sequence is adopted' test "$(seq_file)" == 2
printf 'PASS a sequence that went backwards resyncs without waking a slot\n'

# With every slot busy the signal is spent, exactly as a new head is in the fallback: the running
# ticks and the slot timers behind them pick that work up.
touch "$fx/busy-0" "$fx/busy-1" "$fx/busy-2"
signal 3 "$(wanted acme/acme-a "$A2" regate)"
run
must 'no idle slot, nothing started' test "$(started)" == 0
must 'says so' grep -q 'none idle' "$fx/out"
must 'the signal is not kept for later' test "$(seq_file)" == 3
rm -f "$fx"/busy-*
printf 'PASS all slots busy: the signal is spent and the timers pick it up\n'

# A forge that answers the signal route with something unusable falls back to reading heads, so the
# timer path keeps working against a forge that does not have the signal.
printf '{"seq":"not-a-number","signals":[]}' >"$fx/forge/wanted.json"
if run 2>"$fx/err"; then printf 'FAIL: a nonnumeric sequence was accepted\n' >&2; exit 1; fi
must 'nonnumeric sequence refused' grep -q 'nonnumeric gate-wanted sequence' "$fx/err"
printf '{"signals":[]}' >"$fx/forge/wanted.json"
pulls a "$(pr 1 "$A1")"
run
must 'an answer with no sequence reads heads instead' grep -q 'no gate-wanted signal' "$fx/out"
must 'and records the head view' grep -qx "acme/acme-a 1 $A1" "$fx/home/cache/wake-heads"
printf 'PASS a forge without a usable signal falls back to reading gated heads\n'

: >"$fx/curl.log"
if GATE_RUNNER_WAKE_WAIT=x run 2>"$fx/err"; then
  printf 'FAIL: a nonnumeric wait was accepted\n' >&2; exit 1; fi
must 'a nonnumeric wait is refused' grep -q 'GATE_RUNNER_WAKE_WAIT' "$fx/err"
must 'and nothing was requested' test "$(grep -c . "$fx/curl.log" || true)" == 0
printf 'PASS the wait is validated before any request\n'

# ---------------------------------------------------------------------------
# What the signal cannot say, and what the woken slot is told. A pull request opened on a branch
# that was already pushed got its push signal before it existed, so no signal names it now: only the
# open-PR view does. Each started slot is handed the head it was started for.
# ---------------------------------------------------------------------------
rm -rf -- "$fx/home"; mkdir -p "$fx/home/cache"
printf 'acme/acme-a\n' >"$fx/home/cache/protected-acme"
pulls a; pulls b; printf '{"entries":[]}' >"$fx/forge/queue.json"; rm -f "$fx/forge/regate.json"
dispatch() { cat "$fx/home/cache/wake-dispatch" 2>/dev/null || true; }
signal 4
run
must 'nothing open yet, nothing woken' test "$(started)" == 0
must 'and no head was handed to anybody' test "$(dispatch)" == ""

pulls a "$(pr 5 "$A1")"
GATE_RUNNER_WAKE_HEADS_EVERY=0 run
must 'an opened pull request wakes a slot although no signal names it' test "$(started)" == 1
# The time is "-": the view says when it was read, not when the pull request was opened, and the
# runner dates such a head from the pull request itself.
must 'and the slot is told which head' test "$(dispatch)" == "acme/acme-a 5 $A1 pr-head -"
printf 'PASS a pull request opened on an already-pushed branch wakes a slot from the open-PR view\n'

: >"$fx/home/cache/wake-dispatch"
signal 7 "$(wanted acme/acme-a "$A2" push)"
pulls a "$(pr 5 "$A2")"
GATE_RUNNER_WAKE_HEADS_EVERY=0 run
must 'a signalled push wakes exactly one slot, not one per source' test "$(started)" == 1
must 'and carries the moment the forge recorded it' \
  test "$(dispatch)" == "acme/acme-a - $A2 push 2026-10-08T09:00:00Z"
printf 'PASS a head the signal reported is not woken for twice by the open-PR view\n'

: >"$fx/home/cache/wake-dispatch"
touch "$fx/busy-1" "$fx/busy-2"
signal 9 "$(wanted acme/acme-a "$B1" push)" "$(wanted acme/acme-a "$Q1" queue)"
run
must 'one idle slot, one slot started' test "$(started)" == 1
must 'and one head handed over, the first of the two' \
  test "$(dispatch)" == "acme/acme-a - $B1 push 2026-10-08T09:00:00Z"
rm -f "$fx"/busy-*
printf 'PASS a head with no idle slot to take it is not handed to anybody\n'

# The file cannot grow without bound: it is the newest few heads, not a backlog.
for i in $(seq 1 70); do printf 'acme/acme-a %s %s pr-head -\n' "$i" "$A1" >>"$fx/home/cache/wake-dispatch"; done
signal 11 "$(wanted acme/acme-a "$A1" regate)"
run
must 'the dispatch file is held to its newest lines' test "$(dispatch | wc -l)" -le 64
must 'and the newest head is the one just handed over' test "$(dispatch | tail -1)" == "acme/acme-a - $A1 regate 2026-10-08T09:00:00Z"
printf 'PASS the handed-over heads are bounded\n'
