#!/usr/bin/env bash
# Exercise pr-gate-wake.sh against a fixture forge and a systemctl shim that records what it starts.
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
