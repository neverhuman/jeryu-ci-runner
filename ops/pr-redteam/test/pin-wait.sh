#!/usr/bin/env bash
# Every PR waits for enforced required contexts; pin bumps share the bounded path with their
# existing timeout. Missing-result-only holds do not spend the agent hold cap. Offline fixtures.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
finish() {
  local result=$?
  if ((result != 0)); then tail -60 "$t/controller.log" 2>/dev/null || true; fi
  rm -rf -- "$t"
}
trap finish EXIT
fail() { echo "FAIL $1" >&2; exit 1; }
real_git="$(command -v git)"
fixture_git() {
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_AUTHOR_DATE \
    -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL -u GIT_COMMITTER_DATE "$real_git" "$@"
}
mkdir -p "$t/bin" "$t/state" "$t/repo"
printf 'fixture-bearer\n' >"$t/token"
fixture_git init -q -b main "$t/repo"
g() { fixture_git -C "$t/repo" -c user.name=fixture -c user.email=fixture@example.invalid "$@"; }
printf 'base\n' >"$t/repo/README.md"
printf '[[repo]]\nname = "web"\ncommit = "%s"\n' "$(printf 'a%.0s' {1..40})" >"$t/repo/acme.lock.toml"
g add .; g commit -qm base; g rev-parse HEAD >"$t/base"
g switch -qc topic
bump() { printf '# bump %s\n' "$RANDOM$RANDOM" >>"$t/repo/acme.lock.toml"; g commit -qam bump; g rev-parse HEAD >"$t/head"; }
bump
printf 'main\n' >"$t/base-ref"
g branch release/pilot "$(cat "$t/base")"
g branch release/unchanged "$(cat "$t/base")"

cat >"$t/bin/git" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  case "$arg" in
    push|rebase|--force-with-lease*) echo forbidden-history-write >>"$PIN_FIXTURE/danger"; exit 97 ;;
    https://forge.invalid/git/acme/fixture.git) args+=("$PIN_FIXTURE/repo") ;;
    *) args+=("$arg") ;;
  esac
done
exec "$FIXTURE_REAL_GIT" "${args[@]}"
FIXTURE
cat >"$t/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
method=GET data=''
while (($#)); do
  case "$1" in
    --config) [[ "$2" != - ]] || cat >/dev/null; shift ;;
    -X) method="$2"; shift ;;
    --data) data="$2"; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
printf '%s %s\n' "$method" "$url" >>"$PIN_FIXTURE/requests"
head="$(cat "$PIN_FIXTURE/head")"
case "$url" in
  */api/v3/user) printf '{"login":"independent-reviewer"}\n200' ;;
  *'/pulls?state=open')
    jq -nc --arg sha "$head" --arg base "$(cat "$PIN_FIXTURE/base")" --arg base_ref "$(cat "$PIN_FIXTURE/base-ref")" --slurpfile ctx "$PIN_FIXTURE/contexts" \
      '{items: [{repo: {owner: "acme", name: "fixture"}, number: 1, head_sha: $sha, base_sha: $base,
        head_ref: "topic", base_ref: $base_ref, draft: false, author: "pinbot", title: "release: pin web",
        state: "open", labels: ["origin:internal"], passport_hash: "p", review: {changes_requested: 0},
        mergeable: {can_merge: false}}
        + (if $ctx[0] == "absent" then {} else {required_contexts: $ctx[0]} end)]}'
    printf '\n200' ;;
  */pulls/1/diff)
    if [[ -e "$PIN_FIXTURE/diff-down" ]]; then printf '{"message":"unavailable"}\n503'; exit 0; fi
    jq -nc --arg sha "$(if [[ -e "$PIN_FIXTURE/diff-stale" ]]; then echo stale; else echo "$head"; fi)" \
      --argjson truncated "$(test -e "$PIN_FIXTURE/diff-truncated" && echo true || echo false)" \
      --slurpfile files "$PIN_FIXTURE/diff-files" \
      '{head_sha: $sha, base_sha: "b", truncated: $truncated,
        files: ($files[0] | map({path: ., old_path: null, status: "modified", hunks: []}))}'
    printf '\n200' ;;
  */refs) printf '[]\n200' ;; # No protected-main boundary in this fixture.
  */branches/*/protection)
    ref="${url#*/branches/}"; ref="${ref%/protection}"
    if [[ "$(cat "$PIN_FIXTURE/protection")" == unreadable ]]; then printf '{"message":"server error"}\n500'; exit 0; fi
    if out="$(jq -ce --arg ref "$ref" '.[$ref]' "$PIN_FIXTURE/protection")"; then
      printf '%s\n200' "$out"
    else
      printf '{"message":"Branch not protected"}\n404'
    fi ;;
  */pulls/1) printf '{"merge_passport":{"blockers":[]}}\n200' ;;
  */pulls/1/checks) printf '{"checks":[]}\n200' ;;
  */check-runs) jq -c . <<<"$data" >>"$PIN_FIXTURE/check-runs"; printf '{"id":"c"}\n201' ;;
  */reviews) jq -c . <<<"$data" >>"$PIN_FIXTURE/posts"; printf '{"ok":true}\n201' ;;
  */api/v1/events) printf '{"ok":true}\n201' ;;
  *) printf 'forbidden API %s\n' "$url" >>"$PIN_FIXTURE/danger"; exit 98 ;;
esac
FIXTURE
cat >"$t/bin/model" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then echo '9.9.9 (Claude Code)'; exit 0; fi
PIN_FIXTURE="$(dirname "$(dirname "$0")")"
while (($#)); do [[ "$1" != --add-dir ]] || cp "$2/signals.txt" "$PIN_FIXTURE/signals.txt"; shift; done
printf 'called\n' >>"$PIN_FIXTURE/model-calls"
if [[ -f "$PIN_FIXTURE/verdict" ]]; then
  jq -c '{type:"result",subtype:"success",is_error:false,structured_output:.}' "$PIN_FIXTURE/verdict"
else
  printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"verdict":"approve","summary":"fixture review","findings":[]}}\n'
fi
FIXTURE
chmod +x "$t/bin/"*
export PIN_FIXTURE="$t" FIXTURE_REAL_GIT="$real_git"
export PATH="$t/bin:$PATH" JERYU_TOKEN_FILE="$t/token" REDTEAM_STATE="$t/state" REDTEAM_CLAUDE="$t/bin/model"
export REDTEAM_CLAUDE_VERSION=9.9.9 REDTEAM_TIMEOUT=10 JERYU_BASE=https://forge.invalid
unset REDTEAM_PIN_WAIT_SECS REDTEAM_GATE_WAIT_SECS

review() { "$here/pr-redteam" _review 0 0 0 acme/fixture 1 >>"$t/controller.log" 2>&1; }
receipt() { printf '%s/state/receipts/acme/fixture/1-%s.json\n' "$t" "$(cat "$t/head")"; }
waitfile() { printf '%s/state/pin-wait/acme/fixture/1-%s.json\n' "$t" "$(cat "$t/head")"; }
count() { if [[ -f "$1" ]]; then wc -l <"$1"; else echo 0; fi; }
diff_reads() { grep -c '/pulls/1/diff' "$t/requests" || true; }
contexts() { printf '%s\n' "$1" >"$t/contexts"; }
# What the forge enforces per branch: a branch absent from this map has no protection (404), and
# "unreadable" makes the forge answer 500 for every branch.
protect() { printf '%s\n' "$1" >"$t/protection"; }
protect '{"main": {"required_status_checks": {"contexts": ["acme/required"]}}}'
protection_reads() { grep -c '/protection' "$t/requests" || true; }
files() { printf '%s\n' "$1" >"$t/diff-files"; }
reviewed() { # label: the head was reviewed and approved, the model ran once more
  [[ "$(count "$t/model-calls")" == "$calls" ]] && jq -e '.decision == "approve" and .posted == true' "$(receipt)" >/dev/null \
    || fail "$1: not reviewed ($(count "$t/model-calls") model calls; $(cat "$(receipt)" 2>/dev/null))"
}
calls=0

# 1. A pin bump with its required context missing waits: no receipt, review, check run or agent.
contexts '[{"name":"acme/required","state":"missing","details":"required context `acme/required` is missing"}]'
files '["acme.lock.toml"]'
review; review
[[ ! -e "$(receipt)" && "$(count "$t/model-calls")" == 0 && "$(count "$t/posts")" == 0 && "$(count "$t/check-runs")" == 0 ]] \
  || fail "a waiting pin bump was reviewed or recorded"
[[ "$(grep -c 'waiting for required contexts' "$t/controller.log")" == 2 ]] && grep -q 'acme/required (missing)' "$t/controller.log" \
  || fail "the wait was not said: $(cat "$t/controller.log")"
[[ "$(diff_reads)" == 1 ]] && jq -e '.pin_only == true and (.first_seen_epoch | type) == "number"' "$(waitfile)" >/dev/null \
  || fail "the forge's diff was not read exactly once per head ($(diff_reads))"
echo 'ok a pin bump waits while its required context is missing, and the diff is read once per head'

# 2. Pending waits too; once the context succeeds the head is reviewed, and the review sees the result.
contexts '[{"name":"acme/required","state":"pending"}]'; review
[[ "$(count "$t/model-calls")" == 0 ]] || fail "reviewed while pending"
contexts '[{"name":"acme/required","state":"success"}]'; review; calls=1; reviewed "context green"
grep -q '^## required contexts on this head' "$t/signals.txt" && grep -qx 'acme/required: success' "$t/signals.txt" \
  && ! grep -q 'waited' "$t/signals.txt" || fail "signals did not carry the context result: $(cat "$t/signals.txt")"
grep -q "include pr-redteam/review, this reviewer's own check run" "$t/signals.txt" || fail "own check not called out: $(cat "$t/signals.txt")"
echo 'ok once the required context reports, the pin bump is reviewed with the result in signals.txt'

# 3. A failing context is a result: reviewed at once (and the reviewer holds as it sees fit).
bump; contexts '[{"name":"acme/required","state":"failing"}]'; review; calls=2; reviewed "context failing"
grep -qx 'acme/required: failing' "$t/signals.txt" || fail "failing state not shown: $(cat "$t/signals.txt")"
echo 'ok a pin bump whose required context failed is reviewed at once'

# 4. The wait is bounded: past REDTEAM_PIN_WAIT_SECS the head is reviewed, told the context is pending.
bump; contexts '[{"name":"acme/required","state":"pending"}]'; REDTEAM_PIN_WAIT_SECS=600 review
[[ "$(count "$t/model-calls")" == 2 ]] || fail "reviewed inside the bound"
jq --argjson e "$(( $(date +%s) - 601 ))" '.first_seen_epoch = $e' "$(waitfile)" >"$t/w" && cat "$t/w" >"$(waitfile)"
REDTEAM_PIN_WAIT_SECS=600 review; calls=3; reviewed "bound reached"
grep -qx 'acme/required: pending' "$t/signals.txt" \
  && grep -q 'waited [0-9]*s (bound 600s) for its required contexts; still without a result: acme/required (pending)' "$t/signals.txt" \
  || fail "signals did not say the bound ran out: $(cat "$t/signals.txt")"
echo 'ok past the bound a pin bump is reviewed and told its required context is still pending'

# 5. Non-pin changes share the wait, using the 5400s general default. No review is spent inside
#    the bound; expiry reviews with the pending state, and each new head starts a fresh clock.
for case in 'source:["acme.lock.toml","src/main.rs"]' 'nested:["sub/acme.lock.toml"]' 'cargo:["Cargo.lock"]'; do
  bump; contexts '[{"name":"acme/required","state":"pending"}]'; files "${case#*:}"; review
  [[ "$(count "$t/model-calls")" == "$calls" && ! -e "$(receipt)" ]] || fail "${case%%:*}: reviewed before bound"
  jq -e '.pin_only == false' "$(waitfile)" >/dev/null || fail "${case%%:*}: recorded as a pin bump"
  grep -q 'of 5400s)' "$t/controller.log" || fail 'general default not 5400s'
  jq --argjson e "$(( $(date +%s) - 5401 ))" '.first_seen_epoch = $e' "$(waitfile)" >"$t/w" && cat "$t/w" >"$(waitfile)"
  review; calls=$((calls + 1)); reviewed "${case%%:*} expired"
  grep -q 'bound 5400s' "$t/signals.txt" || fail 'general expiry signal missing'
done
echo 'ok ordinary source, nested lock and Cargo.lock changes wait for the general bound'

# 6. An unknown diff cannot bypass the general wait. An unavailable diff is retried while keeping
#    the first observation, so outages cannot postpone expiry indefinitely.
files '["acme.lock.toml"]'
for flag in diff-stale diff-truncated diff-down; do
  bump; touch "$t/$flag"; review
  [[ "$(count "$t/model-calls")" == "$calls" && ! -e "$(receipt)" ]] || fail "$flag bypassed wait"
  first=$(( $(date +%s) - 601 )); first_at="$(date -u -d "@$first" +%FT%TZ)"
  jq --argjson e "$first" --arg at "$first_at" '.first_seen_epoch = $e | .first_seen_at = $at' "$(waitfile)" >"$t/w" && cat "$t/w" >"$(waitfile)"
  REDTEAM_GATE_WAIT_SECS=600 review
  [[ "$(jq -r .first_seen_at "$(waitfile)")" == "$first_at" ]] || fail "$flag reset the first-observation timestamp"
  rm "$t/$flag"; calls=$((calls + 1)); reviewed "$flag expired"
done
echo 'ok stale, truncated and unavailable diffs use the general bound without resetting it'

# 7. Off switch, a base that enforces nothing, and protection the forge will not answer with no row
#    list either: reviewed at once, no diff read.
bump; contexts '[{"name":"acme/required","state":"pending"}]'; before="$(diff_reads)"
REDTEAM_PIN_WAIT_SECS=0 REDTEAM_GATE_WAIT_SECS=0 review; calls=$((calls + 1)); reviewed "wait off"
bump; protect '{"main": {"required_status_checks": {"contexts": []}}}'; contexts '[]'
review; calls=$((calls + 1)); reviewed "none enforced"
grep -qx '(the base branch enforces no required context)' "$t/signals.txt" \
  || fail "no-context signal: $(cat "$t/signals.txt")"
bump; protect '{}'; contexts '"absent"'; review; calls=$((calls + 1)); reviewed "unprotected base"
grep -qx '(the base branch enforces no required context)' "$t/signals.txt" \
  || fail "unprotected base signal: $(cat "$t/signals.txt")"
[[ "$(diff_reads)" == "$before" ]] || fail "the diff was read with nothing to wait for"
echo 'ok with the wait off or nothing enforced, the diff is not read and the head is reviewed'

# 8. The base branch's enforced protection decides, for a main base, a pilot release switched to the
#    fast tier, and a release line whose protection is unchanged. The row's own list never does: a
#    context it reports that protection does not enforce satisfies nothing, and an enforced context
#    the row does not report has no result and is waited for.
protect '{"main": {"required_status_checks": {"contexts": ["acme/required"]}},
          "release/pilot": {"required_status_checks": {"contexts": ["acme/fast"]}},
          "release/unchanged": {"required_status_checks": {"contexts": ["acme/required"]}}}'
for base_ref in main release/pilot release/unchanged; do
  printf '%s\n' "$base_ref" >"$t/base-ref"
  enforced=acme/required other=acme/fast
  [[ "$base_ref" != release/pilot ]] || { enforced=acme/fast; other=acme/required; }
  # Only the context protection does not enforce has a result: the head waits for the enforced one.
  bump; contexts "[{\"name\":\"$other\",\"state\":\"success\"}]"; review
  [[ "$(count "$t/model-calls")" == "$calls" ]] || fail "$base_ref: $other stood in for $enforced"
  grep -q "waiting for required contexts — .*$enforced (no result)" "$t/controller.log" \
    || fail "$base_ref: did not wait for $enforced with no result"
  # Pending is still no result; the enforced context's own success is what releases the head.
  contexts "[{\"name\":\"$enforced\",\"state\":\"pending\"},{\"name\":\"$other\",\"state\":\"success\"}]"
  review; [[ "$(count "$t/model-calls")" == "$calls" ]] || fail "$base_ref: reviewed while $enforced pending"
  contexts "[{\"name\":\"$enforced\",\"state\":\"success\"},{\"name\":\"$other\",\"state\":\"failing\"}]"
  review; calls=$((calls + 1)); reviewed "$base_ref"
  grep -Fqx "$enforced: success" "$t/signals.txt" || fail "$base_ref: enforced context missing from signals"
  ! grep -Fq "$other:" "$t/signals.txt" || fail "$base_ref: judged against $other, which is not enforced"
  grep -Fq "Base branch: \"$base_ref\"." "$t/signals.txt" || fail "$base_ref: missing base"
  grep -Fq 'an upstream commit merged only on a release line is not on main' "$t/signals.txt" \
    || fail "$base_ref: the pin verifier's ancestry requirement was omitted"
done
echo 'ok a main base, a fast-tier pilot release and an unchanged release line are each judged against exactly their enforced contexts'

# 9. Protection the forge will not answer is unresolved evidence, not an empty requirement set: the
#    row's list is still waited for and the review is told the enforced set is unknown.
printf 'main\n' >"$t/base-ref"
bump; protect unreadable; contexts '[{"name":"acme/required","state":"pending"}]'; review
[[ "$(count "$t/model-calls")" == "$calls" ]] || fail "reviewed without waiting while protection was unreadable"
contexts '[{"name":"acme/required","state":"success"}]'; review; calls=$((calls + 1)); reviewed "protection unreadable"
grep -Fq "could not be read" "$t/signals.txt" && grep -Fq 'do not guess contexts' "$t/signals.txt" \
  || fail "unreadable protection was not identified as unresolved: $(cat "$t/signals.txt")"
grep -Fqx 'acme/required: success' "$t/signals.txt" || fail "the row's list was not shown as such"
[[ "$(protection_reads)" -gt 0 ]] || fail "branch protection was never read"
echo 'ok protection the forge will not answer leaves gate evidence unresolved and still waits for the row'

bump; contexts '"absent"'; review; calls=$((calls + 1)); reviewed "unreadable protection without row contexts"
grep -Fq '(the row reported none either)' "$t/signals.txt" || fail 'unknown protection without row contexts was hidden'

# 10. Mixed contexts wait until every required result exists; a failed result does not hide a
#     different missing result. Force and dry-run still respect admission and publish nothing.
protect '{"main": {"required_status_checks": {"contexts": ["acme/required", "acme/extra"]}}}'
files '["src/main.rs"]'; bump
contexts '[{"name":"acme/required","state":"failure"},{"name":"acme/extra","state":"pending"}]'
review
"$here/pr-redteam" _review 1 1 0 acme/fixture 1 >>"$t/controller.log" 2>&1
[[ "$(count "$t/model-calls")" == "$calls" && ! -e "$(receipt)" ]] || fail 'mixed results/force bypassed wait'
contexts '[{"name":"acme/required","state":"failure"},{"name":"acme/extra","state":"success"}]'
review; calls=$((calls + 1)); reviewed 'all contexts terminal'
echo 'ok every enforced context needs a result, including under force and dry-run'

# 11. Expired missing-result-only blocks stay blocking but do not consume the hold cap. A real
#     code finding mixed in still counts, as do false labels for failed or unknown contexts.
protect '{"main": {"required_status_checks": {"contexts": ["acme/required"]}}}'
contexts '[{"name":"acme/required","state":"missing"}]'
missing='{severity:"medium",title:"Required result missing",file:"signals.txt",
  detail:"The required lane has no result yet.",evidence:"acme/required: missing",
  pending_required_context:"acme/required"}'
advice='{severity:"low",title:"Name the unit",file:"cart.rs",detail:"Name the unit in the local variable.",evidence:"total"}'
code_finding='{severity:"high",title:"Client total trusted",file:"cart.rs",
  detail:"The server accepts the client total.",evidence:"body.total"}'
for _attempt in 1 2 3; do
  bump
  jq -n "{verdict:\"block\",summary:\"Required evidence has not arrived\",findings:[$missing]}" >"$t/verdict"
  REDTEAM_GATE_WAIT_SECS=0 review; calls=$((calls + 1))
  [[ "$(count "$t/model-calls")" == "$calls" ]] || fail 'missing results exhausted the hold cap'
  jq -e '.decision == "hold" and .hold_kind == "gate" and .posted == true' "$(receipt)" >/dev/null || fail 'missing-only hold counted'
  tail -1 "$t/posts" | jq -e '.verdict == "request_changes" and (.body_markdown | contains("required-context hold, not counted toward the hold limit"))' >/dev/null \
    || fail 'missing-only hold was waived or misreported'
done
printf '%200s' fixture >"$t/repo/payload.bin"
g add payload.bin; g commit -qm 'add unpinned fixture payload'; g rev-parse HEAD >"$t/head"
REDTEAM_MAX_BLOB_BYTES=100 REDTEAM_GATE_WAIT_SECS=0 review; calls=$((calls + 1))
grep -Fq 'admission wait is disabled (bound 0s)' "$t/signals.txt" || fail 'zero-bound signal claimed an expired wait'
jq -e '.decision == "hold" and .hold_kind == "gate" and .posted == true
  and any(.verdict.findings[]; .title | startswith("Unpinned binary or archive"))' "$(receipt)" >/dev/null \
  || fail 'mechanical finding made a missing-only model hold count'
g rm -q payload.bin; g commit -qm 'remove fixture payload'
bump
jq -n "{verdict:\"block\",summary:\"Missing result and code defect\",findings:[$missing,$code_finding]}" >"$t/verdict"
REDTEAM_GATE_WAIT_SECS=0 review; calls=$((calls + 1))
jq -e '.decision == "hold" and .hold_kind == "agent"' "$(receipt)" >/dev/null || fail 'mixed code hold did not count'
tail -1 "$t/posts" | jq -e '.body_markdown | contains("hold 1 of 2")' >/dev/null || fail 'missing-only holds moved the count'
bump
jq -n "{verdict:\"block\",summary:\"Missing result with advice\",findings:[$missing,$advice]}" >"$t/verdict"
REDTEAM_HOLD_CAP=0 REDTEAM_GATE_WAIT_SECS=0 review; calls=$((calls + 1))
jq -e '.decision == "hold" and .hold_kind == "agent" and (.verdict.findings | length) == 2' "$(receipt)" >/dev/null \
  || fail 'low model advice was segregated out of a blocking review'
for kind in failed unknown unreadable; do
  bump
  contexts '[{"name":"acme/required","state":"failure"}]'
  jq -n "{verdict:\"block\",summary:\"Unresolved evidence\",findings:[$missing]}" >"$t/verdict"
  if [[ "$kind" == unknown ]]; then
    contexts '[{"name":"acme/required","state":"pending"}]'
    jq '.findings[0].pending_required_context="invented/required"' "$t/verdict" >"$t/v"; mv "$t/v" "$t/verdict"
  elif [[ "$kind" == unreadable ]]; then
    contexts '[{"name":"acme/required","state":"pending"}]'; protect unreadable
  fi
  REDTEAM_HOLD_CAP=0 REDTEAM_GATE_WAIT_SECS=0 review; calls=$((calls + 1))
  jq -e '.decision == "hold" and .hold_kind == "agent"' "$(receipt)" >/dev/null || fail "$kind label exempted an agent hold"
done
[[ "$(count "$t/model-calls")" == "$calls" ]] || fail 'accounting model call count'
echo 'ok missing-only holds never spend the cap; mixed, failed, unknown and unverified claims count'

# 12. A lane that never reports serves out the enabled default bound: inside it nothing is spent,
#     at expiry the head is reviewed with the unresolved state, and the missing-only block still
#     blocks without spending the cap, head after head. The signal names the wait it served out
#     rather than the disabled-bound wording.
protect '{"main": {"required_status_checks": {"contexts": ["acme/required"]}}}'
contexts '[{"name":"acme/required","state":"missing"}]'
for _attempt in 1 2 3; do
  bump
  jq -n "{verdict:\"block\",summary:\"Required evidence has not arrived\",findings:[$missing]}" >"$t/verdict"
  REDTEAM_HOLD_CAP=99 review
  [[ "$(count "$t/model-calls")" == "$calls" && ! -e "$(receipt)" ]] || fail 'a never-reporting lane was reviewed inside the bound'
  jq --argjson e "$(( $(date +%s) - 5401 ))" '.first_seen_epoch = $e' "$(waitfile)" >"$t/w" && cat "$t/w" >"$(waitfile)"
  REDTEAM_HOLD_CAP=99 review; calls=$((calls + 1))
  [[ "$(count "$t/model-calls")" == "$calls" ]] || fail 'expired missing-only holds exhausted the hold cap'
  grep -q 'waited [0-9]*s (bound 5400s) for its required contexts; still without a result: acme/required' "$t/signals.txt" \
    || fail "the expiry signal did not name the wait it served out: $(cat "$t/signals.txt")"
  ! grep -Fq 'admission wait is disabled' "$t/signals.txt" || fail 'an expired wait was reported as disabled'
  jq -e '.decision == "hold" and .hold_kind == "gate" and .posted == true' "$(receipt)" >/dev/null \
    || fail 'an expired missing-only hold was counted or left unpublished'
  tail -1 "$t/posts" | jq -e '.verdict == "request_changes" and (.body_markdown | contains("required-context hold, not counted toward the hold limit"))' >/dev/null \
    || fail 'the expired missing-only hold was waived or misreported'
done
rm -f "$t/verdict"
echo 'ok a lane that never reports is reviewed at expiry and its blocking holds never spend the cap'

[[ ! -e "$t/danger" ]] || fail "forbidden action: $(cat "$t/danger")"
echo 'PIN WAIT PASS'
