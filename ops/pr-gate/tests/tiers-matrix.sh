# Sourced by test-pr-gate-runner.sh after constructing its isolated forge.
fail_tier() { printf '%s\n' "$1" >&2; cat "$fixture/runner.log" >&2; exit 1; }
run_tier() { invoke "$@"; [[ "$runner_exit" == 0 ]] || fail_tier 'tier runner failed'; }
last_tier() { jq -s 'last' "$fixture/statuses.jsonl"; }
touch "$fixture/two-tiers"
run_tier
expect_count 2
[[ "$(cat "$fixture/recipes")" == $'required-fast\nrequired' ]] || fail_tier 'main did not run fast then full'
# The fast tier posts only its own context: the full context is left to the full tier.
jq -se 'map([.context,.state]) == [["fixture/fast","pending"],["fixture/fast","success"],
  ["fixture/required","pending"],["fixture/required","success"]]' "$fixture/statuses.jsonl" >/dev/null \
  || fail_tier 'the fast tier posted over the full context'

head=$(cat "$fixture/head")
full="$fixture/runner/attempts/acme-fixture-$head/last-result.json"
fast="$fixture/runner/attempts/acme-fixture-$head/tiers/fast/last-result.json"
jq -e --slurpfile fast "$fast" '.inputs.recipe == "just required" and .inputs.required_context == "fixture/required"
  and $fast[0].inputs.recipe == "just required-fast" and $fast[0].inputs.required_context == "fixture/fast"
  and (.inputs | del(.recipe,.required_context)) == ($fast[0].inputs | del(.recipe,.required_context))' "$full" >/dev/null
run_tier
expect_count 2
printf 'PASS main runs two tiers with distinct evidence and reuses both\n'

# The release branch's name cannot activate fast-only validation.
"$real_git" -C "$fixture/source" branch release/v1
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" release/v1
printf 'release/v1\n' >"$fixture/pr-base-ref"
jq -nc --arg sha "$head" '[{kind:"branch",name:"main",sha:$sha,protected:true},
  {kind:"branch",name:"release/v1",sha:$sha,protected:true}]' >"$fixture/refs.json"
export PR_GATE_PROOF_BASE_VARS=acme=ACME_PROOF_BASE_REF
run_tier
expect_count 4
[[ "$(tail -2 "$fixture/recipes")" == $'required-fast\nrequired' ]] || fail_tier 'unchanged release protection skipped full'
printf 'PASS unchanged release protection requires full validation\n'

jq -nc '{required_status_checks:{contexts:["fixture/fast"]}}' >"$fixture/protection.json"
# Explicit retry proves the activated pilot runs fast alone even with full evidence present.
before_statuses=$(wc -l <"$fixture/statuses.jsonl")
run_tier --repo acme/fixture --pr 1
expect_count 5
jq -se --argjson n "$before_statuses" '.[$n:] | all(.context == "fixture/fast")' "$fixture/statuses.jsonl" >/dev/null
printf 'PASS only enforced fast protection activates fast-only gating\n'

# Neither local nor cross-host evidence may turn fast validation into full validation.
# Delete the full journal; leave only fast receipts and fast statuses from this trusted host.
# Move evidence aside to retain it for diagnosis.
key=$(dirname -- "$(compgen -G "$fixture/runner/attempts/acme-fixture-$head.base-*/last-result.json")")
mv "$key/last-result.json" "$fixture/release-full-result.json"
for receipt in "$key"/*/receipt.json; do
  [[ -f "$receipt" ]] || continue
  mv "$(dirname -- "$receipt")" "$fixture/retained-$(basename -- "$(dirname -- "$receipt")")"
done
jq -sc 'map(select(.context == "fixture/fast"))[]' "$fixture/statuses.jsonl" >"$fixture/fast-only.jsonl"
mv "$fixture/fast-only.jsonl" "$fixture/statuses.jsonl"
# Even under the full context, the fast digest cannot be adopted as full proof.
jq -sc 'last | .context="fixture/required" | .id="mislabelled-fast" | .updated_at += 1' \
  "$fixture/statuses.jsonl" >>"$fixture/mislabelled.jsonl"
cat "$fixture/mislabelled.jsonl" >>"$fixture/statuses.jsonl"
printf '{"required_status_checks":{"contexts":["fixture/required","fixture/fast"]}}\n' >"$fixture/protection.json"
run_tier
expect_count 6
[[ "$(tail -1 "$fixture/recipes")" == required ]] || fail_tier 'fast evidence satisfied a full claim'
last_tier | jq -e '.context == "fixture/required" and .state == "success"' >/dev/null
printf 'PASS fast receipts and trusted fast statuses cannot satisfy full claims\n'

# A new source head fails fast. Full validation must never start.
printf 'fast-fail\n' >"$fixture/source/mode"
"$real_git" -C "$fixture/source" add mode
"$real_git" -C "$fixture/source" commit -qm fast-failure
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
printf 'main\n' >"$fixture/pr-base-ref"
rm "$fixture/protection.json"
run_tier
expect_count 7
[[ "$(tail -1 "$fixture/recipes")" == required-fast ]] || fail_tier 'full ran after fast failed'
jq -se 'map(select(.context == "fixture/fast")) | last | .state == "failure"' "$fixture/statuses.jsonl" >/dev/null
last_tier | jq -e '.context == "fixture/required" and .state == "failure" and (.description | contains("full validation not started"))' >/dev/null
run_tier
expect_count 7
printf 'PASS fast failure publishes immediately, skips full and holds on rerun\n'

touch "$fixture/protection-fail"
run_tier --repo acme/fixture --pr 1
expect_count 7
grep -q 'cannot read enforced contexts' "$fixture/runner.log" || fail_tier 'protection failure did not defer'
printf 'PASS unavailable branch protection never lowers the tier\n'

# A crash after fast execution but before publication must recover fast evidence
# before admitting full validation. The descendant lock covers both journals.
rm "$fixture/protection-fail"
printf 'pass\n' >"$fixture/source/mode"
"$real_git" -C "$fixture/source" add mode
"$real_git" -C "$fixture/source" commit -qm recover-fast-publication
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
touch "$fixture/reject-terminal"
invoke
[[ "$runner_exit" != 0 ]] || fail_tier 'unpublished fast result did not report recovery'
expect_count 8
head=$(cat "$fixture/head")
fast="$fixture/runner/attempts/acme-fixture-$head/tiers/fast/last-result.json"
jq -e '.terminal and .outcome == "success" and (.publication.required_status | not)' "$fast" >/dev/null
rm "$fixture/reject-terminal"
run_tier
expect_count 9
jq -e '.publication.required_status and .publication.check_run' "$fast" >/dev/null
last_tier | jq -e '.context == "fixture/required" and .state == "success"' >/dev/null
printf 'PASS retained fast publication recovers before full validation without rerunning fast\n'

# A branch tip's existing full green is subject to the same complete identity
# checks. The earlier PR proof had a different base, and changed tools invalidate
# the branch proof too; neither status-only shortcut may adopt it.
"$real_git" -C "$fixture/source" branch release/tiers
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" release/tiers
jq -nc --arg sha "$head" '[{kind:"branch",name:"main",sha:$sha,protected:true},
  {kind:"branch",name:"release/tiers",sha:$sha,protected:true}]' >"$fixture/refs.json"
run_tier --branch release/tiers
expect_count 11
printf 'changed tool bytes\n' >"$fixture/tools/environment-probe"
run_tier --branch release/tiers
expect_count 13
printf 'PASS branch-tip greens require complete full identities on tiered repositories\n'

# Compatibility: tier membership is the repository's. A repository whose recipes do not
# include required-fast gates exactly as today -- one full run on the full context, no
# protection-driven tier, no tier journal -- even when the base's enforced contexts name
# the fast context.
rm "$fixture/two-tiers"
printf 'main\n' >"$fixture/pr-base-ref"
jq -nc --arg sha "$head" '[{kind:"branch",name:"main",sha:$sha,protected:true}]' >"$fixture/refs.json"
jq -nc '{required_status_checks:{contexts:["fixture/fast"]}}' >"$fixture/protection.json"
printf 'pass\n' >"$fixture/source/mode"
printf 'untiered head\n' >"$fixture/source/untiered"
"$real_git" -C "$fixture/source" add mode untiered
"$real_git" -C "$fixture/source" commit -qm untiered-repository
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
head=$(cat "$fixture/head")
before_statuses=$(wc -l <"$fixture/statuses.jsonl")
run_tier
expect_count 14
[[ "$(tail -1 "$fixture/recipes")" == required ]] || fail_tier 'an untiered repository did not run full validation'
jq -se --argjson n "$before_statuses" '.[$n:] | all(.context == "fixture/required")' "$fixture/statuses.jsonl" >/dev/null
last_tier | jq -e '.state == "success"' >/dev/null
[[ ! -e "$fixture/runner/attempts/acme-fixture-$head/tiered" ]] || fail_tier 'an untiered head recorded a tier'
[[ ! -d "$fixture/runner/attempts/acme-fixture-$head/tiers" ]] || fail_tier 'an untiered head kept a tier journal'
printf 'PASS a repository without required-fast gates full validation as today\n'

# A tiered head whose full tier failed holds that failure, and the full context stays the failure
# even when the fast tier has to run again (its journal gone): nothing posts pending over it.
touch "$fixture/two-tiers"
rm -f "$fixture/protection.json"
printf 'full tier fails\n' >"$fixture/source/untiered"
"$real_git" -C "$fixture/source" add untiered
"$real_git" -C "$fixture/source" commit -qm full-tier-failure
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
head=$(cat "$fixture/head")
jq -nc --arg sha "$head" '[{kind:"branch",name:"main",sha:$sha,protected:true}]' >"$fixture/refs.json"
required_state() { jq -sr 'map(select(.context == "fixture/required")) | last | .state' "$fixture/statuses.jsonl"; }
touch "$fixture/full-fail"
before=$(count)
run_tier
expect_count "$((before + 2))"
[[ "$(required_state)" == failure ]] || fail_tier 'the full failure was not published'
run_tier
expect_count "$((before + 2))"
mv "$fixture/runner/attempts/acme-fixture-$head/tiers/fast" "$fixture/retained-fast-$head"
run_tier
expect_count "$((before + 3))"
[[ "$(tail -1 "$fixture/recipes")" == required-fast ]] || fail_tier 'the held full failure was re-run'
[[ "$(required_state)" == failure ]] || fail_tier 'a fast re-run replaced the held full failure'
printf 'PASS a held full failure stays published while the fast tier runs again\n'

# A forge re-gate of that head re-runs the full tier too: the fast tier honouring the request
# must not leave the full tier holding the failure the request asked to re-run.
rm "$fixture/full-fail"
jq -nc --arg s "$head" \
  '{requests:[{repo:"acme/fixture",number:1,head_sha:$s,requested_at:"2026-10-29T10:00:00Z",requested_by:"dana"}]}' \
  >"$fixture/regate.json"
before=$(count)
run_tier
[[ "$(tail -1 "$fixture/recipes")" == required ]] || fail_tier 'a re-gate did not re-run the full tier'
(( $(count) > before )) || fail_tier 'a re-gate ran nothing'
[[ "$(required_state)" == success ]] || fail_tier 'a re-gate left the full context unresolved'
[[ "$(cat "$fixture/runner/regate/acme-fixture-$head")" == 2026-10-29T10:00:00Z ]] || fail_tier 'the re-gate was not recorded'
after=$(count)
run_tier
expect_count "$after"
rm -f "$fixture/regate.json"
printf 'PASS a forge re-gate of a tiered head re-runs its failed full tier\n'
