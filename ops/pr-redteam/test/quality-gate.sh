#!/usr/bin/env bash
# The quality gate the reviewer honors: where the base branch requires
# `jankurai/proof`, only a passing proof on the exact head can be approved, and
# the hold says why in the gate's own words. A proof with no result yet is not a
# hold but a wait, so the head keeps its next pass. Offline: the controller's
# gate reader is driven with the documents the forge would have answered with.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
printf 'dummy\n' >"$t/token"

detail() { # blocker-message (empty for none)
  if [ -z "${1:-}" ]; then printf '{"merge_passport":{"blockers":[]}}\n'
  else jq -nc --arg m "$1" '{merge_passport: {blockers: [{code: "x", message: $m}]}}'; fi
}
checks() { # proof title (empty for no proof row)
  if [ -z "${1:-}" ]; then printf '{"checks":[]}\n'
  else jq -nc --arg t "$1" '{checks: [{name: "jankurai/proof", title: $t, required: true}]}'; fi
}
gate() { # detail-json checks-json -> "hold|wait<TAB>reason" on stdout
  printf '%s\n' "$1" >"$t/detail.json"; printf '%s\n' "$2" >"$t/checks.json"
  REDTEAM_STATE="$t/state" JERYU_TOKEN_FILE="$t/token" \
    "$here/pr-redteam" _gate "$t/detail.json" "$t/checks.json"
}

fail=0
expect_empty() { # label detail checks
  local out; out="$(gate "$2" "$3")"
  if [ -z "$out" ]; then echo "ok $1: no hold"; else echo "FAIL $1: held on '$out'"; fail=1; fi
}
expect_reason() { # disposition label detail checks needle...
  local want="$1" label="$2" out; out="$(gate "$3" "$4")"; shift 4
  if [[ "${out%%$'\t'*}" != "$want" ]]; then echo "FAIL $label: wanted $want, got '$out'"; fail=1; return; fi
  for needle in "$@"; do
    if [[ "$out" != *"$needle"* ]]; then echo "FAIL $label ${needle}: '$out'"; fail=1; return; fi
  done
  echo "ok $want: ${out#*$'\t'}"
}
expect_hold() { expect_reason hold "$@"; }
expect_wait() { expect_reason wait "$@"; }

# A repository outside the rollout does not require the proof, so a red proof is
# not a hold here: that is what keeps a repo whose main is below the floor open.
expect_empty "gate off, proof red" "$(detail "")" "$(checks "score 47 < floor 85")"
expect_empty "gate on, proof green" "$(detail "")" "$(checks "score 92 >= floor 85")"
# Another blocker is not this gate's business.
expect_empty "unrelated blocker" \
  "$(detail 'Required context `ci/required` is failing.')" "$(checks "score 92 >= floor 85")"

expect_hold "failing proof" \
  "$(detail 'Required context `jankurai/proof` is failing.')" \
  "$(checks "score 47 < floor 85")" \
  "jankurai/proof" "is failing" "score 47 < floor 85"
expect_hold "scorer failure" \
  "$(detail 'Required context `jankurai/proof` is failing.')" \
  "$(checks "jankurai audit produced no score: the auditor exited 101")" \
  "produced no score" "the auditor exited 101"
# A proof with no result yet says nothing about this head. Holding it would post
# a block and record the head reviewed, so it could never merge until somebody
# pushed another commit; the reviewer waits for the result instead.
expect_wait "missing proof" \
  "$(detail 'Required context `jankurai/proof` has not run on this head.')" \
  "$(checks "")" \
  "has not run on this head"
expect_wait "pending proof" \
  "$(detail 'Required context `jankurai/proof` is queued or running.')" \
  "$(checks "")" \
  "queued or running"
# A proof that is running again after a failure is still failing on this head.
expect_hold "failing proof, rerun queued" \
  "$(detail 'Required context `jankurai/proof` is failing.')" \
  "$(checks "queued or running after score 47 < floor 85")" \
  "is failing"

((fail == 0))
echo 'QUALITY GATE PASS'
