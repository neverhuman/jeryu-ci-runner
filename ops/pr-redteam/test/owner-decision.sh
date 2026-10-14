#!/usr/bin/env bash
# An owner's recorded decision, as the reviewer reads it: who may record one, what counts as one,
# which findings it answers, and what it never clears. Offline — the controller's own readers are
# driven with the documents the forge would have answered with.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
printf 'dummy\n' >"$t/token"

# A PR detail carrying one review row.
detail() { # author state head-sha body effective
  jq -nc --arg a "$1" --arg s "$2" --arg h "$3" --arg b "$4" --argjson e "$5" \
    '{reviews: [{id: "r1", author: $a, state: $s, head_sha: $h, body_markdown: $b,
                 submitted_at: "2026-10-14T01:02:03Z", effective: $e, stale: false}]}'
}

owner_decision() { # detail-json owner/name sha  [env: REDTEAM_OWNER_DECISION_AUTHORS]
  printf '%s\n' "$1" >"$t/detail.json"
  REDTEAM_STATE="$t/state" JERYU_BASE="${JERYU_BASE:-https://forge.invalid}" \
    JERYU_TOKEN_FILE="$t/token" "$here/pr-redteam" _owner_decision "$t/detail.json" "$2" "$3"
}

satisfy() { # verdict-json decision-json
  printf '%s\n' "$1" >"$t/verdict.json"; printf '%s\n' "$2" >"$t/decision.json"
  REDTEAM_STATE="$t/state" JERYU_BASE="${JERYU_BASE:-https://forge.invalid}" \
    JERYU_TOKEN_FILE="$t/token" "$here/pr-redteam" _owner_satisfy "$t/verdict.json" "$t/decision.json"
}

body() { # verdict-json decision sha origin decision-json
  printf '%s\n' "$1" >"$t/verdict.json"; printf '%s\n' "$5" >"$t/decision.json"
  REDTEAM_STATE="$t/state" JERYU_BASE="${JERYU_BASE:-https://forge.invalid}" \
    JERYU_TOKEN_FILE="$t/token" "$here/pr-redteam" _owner_body "$t/verdict.json" "$2" "$3" "$4" "$t/decision.json"
}

sha=1111111111111111111111111111111111111111
other=2222222222222222222222222222222222222222
# The incident this exists for: a pr-redteam hold whose one high finding was that nobody had
# recorded an owner decision, posted nine seconds before the owner's approval landed.
ask='{"severity":"high","title":"No recorded owner decision","file":"ops/ci/jankurai-gate.sh","detail":"The ratchet floor drops 94 to 92 and no owner decision is recorded for it.","evidence":"floor 94 -> 92"}'
unrelated='{"severity":"high","title":"Command injection in the deploy hook","file":"ops/deploy.sh","detail":"Interpolates a branch name into a shell command.","evidence":"eval"}'
held="{\"verdict\":\"block\",\"summary\":\"one question for the owner\",\"findings\":[$ask]}"
held_plus="{\"verdict\":\"block\",\"summary\":\"two problems\",\"findings\":[$ask,$unrelated]}"

fail=0
ok() { echo "ok $*"; }
bad() { echo "FAIL $*"; fail=1; }

# --- who may record one, and what counts as one --------------------------------------------------
out="$(owner_decision "$(detail root APPROVED "$sha" 'Owner decision: accepting the ratchet drop.' true)" root/deploy "$sha")"
[ -n "$out" ] && [ "$(jq -r .login <<<"$out")" = root ] \
  && ok "the namespace owner's stated decision counts" || bad "namespace owner: '$out'"

out="$(REDTEAM_OWNER_DECISION_AUTHORS="alton2 someone" owner_decision \
  "$(detail alton2 APPROVED "$sha" 'Owner decision: the jankurai ratchet drop is accepted.' true)" root/deploy "$sha")"
[ "$(jq -r .login <<<"$out")" = alton2 ] && ok "a listed owner's stated decision counts" \
  || bad "listed owner: '$out'"
[[ "$out" == *"ratchet drop is accepted"* ]] && ok "the decision carries its own words" \
  || bad "excerpt missing: '$out'"

out="$(owner_decision "$(detail alton2 APPROVED "$sha" 'Owner decision: accepted.' true)" root/deploy "$sha")"
[ -z "$out" ] && ok "an unlisted login records nothing, however worded" || bad "unlisted: '$out'"

out="$(owner_decision "$(detail root APPROVED "$sha" 'Looks good to me.' true)" root/deploy "$sha")"
[ -z "$out" ] && ok "an approval with no stated decision is not a decision" || bad "bare approval: '$out'"

out="$(owner_decision "$(detail root APPROVED "$other" 'Owner decision: accepted.' true)" root/deploy "$sha")"
[ -z "$out" ] && ok "a decision on another head does not reach this one" || bad "wrong head: '$out'"

out="$(owner_decision "$(detail root APPROVED "$sha" 'Owner decision: accepted.' false)" root/deploy "$sha")"
[ -z "$out" ] && ok "a dismissed review records nothing" || bad "stale review: '$out'"

out="$(owner_decision "$(detail root CHANGES_REQUESTED "$sha" 'Owner decision: accepted.' true)" root/deploy "$sha")"
[ -z "$out" ] && ok "only an approval records a decision" || bad "changes requested: '$out'"

decision="$(owner_decision "$(detail root APPROVED "$sha" 'Owner decision: accepting the ratchet drop.' true)" root/deploy "$sha")"

# --- what it answers -----------------------------------------------------------------------------
out="$(satisfy "$held" "$decision")"
[ "$(jq -r .verdict <<<"$out")" = approve ] && ok "the hold lifts when the owner's question was the only one" \
  || bad "hold not lifted: $out"
[ "$(jq '.findings | length' <<<"$out")" = 1 ] && ok "the finding stays in the review" \
  || bad "finding dropped: $out"
[ "$(jq -r '.findings[0].severity' <<<"$out")" = low ] && ok "the answered finding reads as answered" \
  || bad "severity: $out"
[[ "$(jq -r '.findings[0].detail' <<<"$out")" == *"Satisfied: root recorded an owner decision"* ]] \
  && ok "the finding says which decision answered it" || bad "detail: $out"

out="$(satisfy "$held_plus" "$decision")"
[ "$(jq -r .verdict <<<"$out")" = block ] && ok "another high finding still holds the head" \
  || bad "wrongly approved: $out"
[ "$(jq -r '.findings[1].severity' <<<"$out")" = high ] && ok "the unrelated finding is untouched" \
  || bad "unrelated finding changed: $out"

# --- the published review ------------------------------------------------------------------------
out="$(body "$(satisfy "$held" "$decision")" approve "$sha" internal "$decision")"
[[ "$out" == *"Owner decision recorded."* ]] && ok "the review names the decision it acted on" \
  || bad "body misses the decision: $out"
[[ "$out" == *"No recorded owner decision"* ]] && ok "the review still lists what was cleared" \
  || bad "body hides the finding: $out"

((fail == 0))
echo 'OWNER DECISION PASS'
