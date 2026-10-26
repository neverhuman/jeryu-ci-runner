#!/usr/bin/env bash
# Attempt evidence is retained: nothing in the runner or its state library removes an attempt journal
# or a log, and the one path that rewrites other attempts' receipts (gate_discharge_other_keys, run
# before every gate) keeps live and unpublished journals intact however many newer keys exist.
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
runner=${1:-$script_dir/pr-gate-runner.sh}
state=${2:-$script_dir/pr-gate-state.sh}
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# The policy is stated where a result is recorded; a runner without it has changed the contract.
grep -q '^# Attempt evidence is retained with its log' "$runner" \
  || fail 'the runner no longer states the attempt-evidence retention policy'
# No removal of attempt journals or logs anywhere in production code. Every rm/find -delete/unlink
# line is listed, and none may name the attempts or logs trees.
removals=$(grep -nE '(^|[^[:alnum:]_-])(rm|unlink)[[:space:]]|-delete([^[:alnum:]_-]|$)' "$runner" "$state" \
  | grep -E 'attempts|/logs|gate_key_dir|gate_attempt_dir|build\.log|receipt\.json|last-result' || true)
[[ -z "$removals" ]] || fail "production code removes attempt evidence:
$removals"

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
# shellcheck source=ops/pr-gate/bin/pr-gate-state.sh
source "$state"
HOME_DIR=$fixture
mkdir -p "$fixture/attempts" "$fixture/claim-locks" "$fixture/logs"
sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
active=acme-fixture-$sha
unpublished=acme-fixture-$sha.base-000000000000-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
current=acme-fixture-$sha.base-111111111111-cccccccccccccccccccccccccccccccccccccccc
for key in "$active" "$unpublished"; do
  mkdir -p "$fixture/attempts/$key/attempt"
  printf 'retained process output\n' >"$fixture/attempts/$key/attempt/build.log"
done
printf '{"terminal":false,"recovery_required":null,"publication":{}}\n' \
  >"$fixture/attempts/$active/attempt/receipt.json"
printf '{"terminal":true,"outcome":"success","publication":{"required_status":false},"recovery_required":"publication denied"}\n' \
  >"$fixture/attempts/$unpublished/attempt/receipt.json"
cp "$fixture/attempts/$unpublished/attempt/receipt.json" "$fixture/attempts/$unpublished/last-result.json"
active_before=$(cat "$fixture/attempts/$active/attempt/receipt.json")
# The active attempt's claim is held, as a running slot holds it.
exec 6>"$fixture/claim-locks/$active.lock"
flock -n 6
touch -d '2000-01-01 UTC' "$fixture/attempts/$active" "$fixture/attempts/$unpublished"
for sequence in $(seq 1 201); do
  printf -v key 'acme-finished-%040x' "$sequence"
  mkdir -p "$fixture/attempts/$key"
done

rc=0
gate_discharge_other_keys acme fixture "$sha" "$current" 2>"$fixture/discharge.log" || rc=$?
((rc != 0)) || fail 'an attempt whose claim is held was not left for the next tick'
for key in "$active" "$unpublished"; do
  [[ -s $fixture/attempts/$key/attempt/receipt.json && -s $fixture/attempts/$key/attempt/build.log ]] \
    || fail "a live or unpublished journal was erased: $key"
done
[[ "$(cat "$fixture/attempts/$active/attempt/receipt.json")" == "$active_before" ]] \
  || fail 'a running attempt'"'"'s receipt was rewritten under its held claim'
jq -e --arg by "proof base: $current" '.terminal and .outcome == "success" and .publication.superseded_by == $by
  and .recovery_required == null' "$fixture/attempts/$unpublished/attempt/receipt.json" >/dev/null \
  || fail 'an unpublished journal was not kept as superseded evidence'
jq -e '.publication.superseded_by != null' "$fixture/attempts/$unpublished/last-result.json" >/dev/null \
  || fail 'the superseded last result still owes publication'
[[ "$(find "$fixture/attempts" -mindepth 1 -maxdepth 1 -name 'acme-finished-*' | wc -l)" == 201 ]] \
  || fail 'newer finished keys were removed'
echo 'PASS: live and unpublished journals survive more than 200 newer keys and a proof-base discharge'
