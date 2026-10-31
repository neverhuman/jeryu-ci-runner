#!/usr/bin/env bash
# Sourced by the real runner fixture after setup, or after its full scheduling matrix.
# --- active-active gate hosts: the forge holds the claim on each gated head ---------------------
# Two hosts gate at once. The lease, not a hand-edited owner list, is what keeps them off each
# other's heads, and an unrenewed lease is what hands a dead host's head to a live one.
printf 'pass\n' >"$fixture/source/mode"
date +%s%N >"$fixture/source/claims-marker"   # a head of its own, whatever the suite left behind
"$real_git" -C "$fixture/source" add -A
"$real_git" -C "$fixture/source" commit -qm claims-fixture
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
head=$(cat "$fixture/head")
claim="$fixture/claims/acme-fixture-$head"
claims_count=$(count)
fail_claims() { printf '%s\n--- runner.log\n' "$1" >&2; cat "$fixture/runner.log" >&2; exit 1; }

# A live lease held by the other host: this host posts nothing at all for that head.
mkdir -p "$fixture/claims"
printf 'gate-b/slot0 gate-b %s\n' "$(( $(date +%s) + 3600 ))" >"$claim"
statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || fail_claims 'a refused claim should not fail the runner'
expect_count "$claims_count"
[[ "$(wc -l <"$fixture/statuses.jsonl")" == "$statuses" ]] \
  || fail_claims 'a host without the claim posted a status on the head'
grep -q 'gate claim refused' "$fixture/runner.log" || fail_claims 'the refusal was not reported'
[[ "$(cut -d' ' -f1 <"$claim")" == gate-b/slot0 ]] || fail_claims 'the refused host took over the lease'
printf 'PASS gate claims: two runners never both post on one head\n'

# The holder is killed: its lease is not renewed, and within one TTL the head is gated here. The
# expired lease is exactly what a killed slot leaves behind.
printf 'gate-b/slot0 gate-b %s\n' "$(( $(date +%s) - 1 ))" >"$claim"
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || fail_claims 'the surviving host did not gate the head'
expect_count "$((claims_count + 1))"
jq -se 'last.state == "success"' "$fixture/statuses.jsonl" >/dev/null \
  || fail_claims 'the head was not re-gated after the lease expired'
grep -q "gate claim held for" "$fixture/runner.log" || fail_claims 'the surviving host did not take the lease'
[[ ! -e "$claim" ]] || fail_claims 'the lease was not released on publication'
printf 'PASS gate claims: a killed runner s head is re-gated by the other host within one TTL\n'

# A head whose repository needs host-ci is refused to a host that does not advertise it, and gated
# by the same host once it does. The policy is the repository s, and the advertisement is the
# heartbeat s: nothing here names an owner.
printf 'acme/fixture\n' >"$fixture/require-host-ci"
statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || fail_claims 'a capability refusal should not fail the runner'
expect_count "$((claims_count + 1))"
[[ "$(wc -l <"$fixture/statuses.jsonl")" == "$statuses" ]] \
  || fail_claims 'a host without host-ci posted a status on a head that needs it'
grep -q 'claim refused' "$fixture/runner.log" || fail_claims 'the capability refusal was not reported'
GATE_RUNNER_CAPABILITIES=host-ci invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || fail_claims 'the capable host did not gate the head'
expect_count "$((claims_count + 2))"
jq -se 'last.state == "success"' "$fixture/statuses.jsonl" >/dev/null \
  || fail_claims 'the capable host did not publish the head'
rm -f "$fixture/require-host-ci"
printf 'PASS gate claims: a head needing host-ci is refused to a host without it\n'

# Without a lease route no host may publish. Upgrade the forge before the runner fleet.
touch "$fixture/no-gate-claims"
statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || fail_claims 'an older forge failed the tick'
expect_count "$((claims_count + 2))"
grep -q 'no gate-claims route' "$fixture/runner.log" || fail_claims 'the older forge was not reported'
[[ "$(wc -l <"$fixture/statuses.jsonl")" == "$statuses" ]] || fail_claims 'an older forge got an unleased publication'
rm -f "$fixture/no-gate-claims"
printf 'PASS gate claims: a forge without the route leaves the head untouched\n'

# An untyped 404 (a proxy, a misrouted forge URL) is not an older forge: the head is left for the
# next tick, nothing is posted, and the route is asked again on the next pass.
touch "$fixture/gate-claims-html-404"
statuses=$(wc -l <"$fixture/statuses.jsonl")
released=$(cat "$fixture/claims-released.log" 2>/dev/null | wc -l)
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || fail_claims 'an untyped 404 failed the runner'
expect_count "$((claims_count + 2))"
[[ "$(wc -l <"$fixture/statuses.jsonl")" == "$statuses" ]] || fail_claims 'an untyped 404 was gated without a lease'
! grep -q 'no gate-claims route' "$fixture/runner.log" || fail_claims 'an untyped 404 switched the lease off'
grep -q 'answered 404' "$fixture/runner.log" || fail_claims 'the untyped 404 was not reported'
[[ "$(cat "$fixture/claims-released.log" 2>/dev/null | wc -l)" == "$released" ]] || fail_claims 'a refused head was released'
rm -f "$fixture/gate-claims-html-404"
printf 'PASS gate claims: only a typed api_route_not_found turns the lease off\n'

# The lease is renewed from the grant, through preparation, not only while the recipe runs: a slot
# kept in preparation longer than a renewal interval (a forge slow to take `pending`) renews it.
# A head of its own, so the slot posts `pending` rather than keeping its own earlier green.
claims_head() {
  date +%s%N >"$fixture/source/claims-marker"
  "$real_git" -C "$fixture/source" add -A
  "$real_git" -C "$fixture/source" commit -qm claims-fixture
  "$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
  "$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
  head=$(cat "$fixture/head"); claim="$fixture/claims/acme-fixture-$head"
}
non_pending() { jq -s '[.[] | select(.state != "pending")] | length' "$fixture/statuses.jsonl"; }
claims_head
printf '30\n' >"$fixture/claim-ttl"
printf '12\n' >"$fixture/pending-sleep"
grants=$(grep -c "acme/fixture $head " "$fixture/claims-granted.log" || true)
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || fail_claims 'the slow-preparation gate failed'
expect_count "$((claims_count + 3))"
# The grant, at least one renewal while `pending` was in flight, and the check before publication.
(( $(grep -c "acme/fixture $head " "$fixture/claims-granted.log") >= grants + 3 )) \
  || fail_claims 'the lease was not renewed during preparation'
jq -se 'last.state == "success"' "$fixture/statuses.jsonl" >/dev/null || fail_claims 'the renewed gate lost its verdict'
printf 'PASS gate claims: the lease is renewed through preparation\n'

# A lease lost during preparation (another host now holds it) ends the attempt before the recipe,
# and nothing but the pending already posted reaches the head.
claims_head
touch "$fixture/steal-on-renew"
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || fail_claims 'a lost lease failed the runner'
expect_count "$((claims_count + 3))"
jq -se 'last.state == "pending"' "$fixture/statuses.jsonl" >/dev/null || fail_claims 'a slot without the lease published'
grep -q 'abandoning attempt' "$fixture/runner.log" || fail_claims 'the lost lease was not reported'
[[ "$(cut -d' ' -f1 <"$claim")" == gate-b/slot0 ]] || fail_claims 'the slot released the other host s lease'
jq -se 'map(select(.outcome == "claim_lost" and .publication.superseded_by != null)) | length >= 1' \
  "$fixture"/runner/attempts/acme-fixture-"$head"*/*/receipt.json >/dev/null \
  || fail_claims 'the abandoned attempt is not recorded as superseded'
rm -f "$fixture/pending-sleep" "$claim"
printf 'PASS gate claims: a lease lost during preparation stops the gate before its recipe\n'

# A completed result whose publication lease is refused stays in the outbox. The
# next tick still posts nothing while another host holds it; after a new grant it
# recovers exactly that verdict without executing the recipe a second time.
rm -f "$fixture/steal-on-renew"
claims_head
touch "$fixture/steal-after-recipe"
results=$(non_pending)
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || fail_claims 'a refused publication was not retained for recovery'
expect_count "$((claims_count + 4))"
[[ "$(non_pending)" == "$results" ]] || fail_claims 'a result was published without the lease'
grep -qE 'publication lease renewal refused|publication lease was lost' "$fixture/runner.log" || fail_claims 'the refusal was not reported'
! grep -q 'abandoning attempt' "$fixture/runner.log" || fail_claims 'a finished verdict was abandoned instead of retained'
receipt="$fixture/runner/attempts/acme-fixture-$head/last-result.json"
jq -e '.terminal and .outcome=="success" and .recovery_required!=null and (.publication.required_status|not)' "$receipt" >/dev/null \
  || fail_claims 'the finished verdict was not retained'
rm -f "$fixture/steal-after-recipe"
invoke
expect_count "$((claims_count + 4))"
[[ "$(non_pending)" == "$results" ]] || fail_claims 'recovery published while another host held the lease'
rm -f "$claim"
invoke
expect_count "$((claims_count + 4))"
jq -e '.publication.required_status and .publication.check_run and .recovery_required==null' "$receipt" >/dev/null \
  || fail_claims 'the saved result was not recovered under a fresh lease'
printf 'PASS gate claims: publication loss retains the completed verdict and recovery requires a new lease\n'

# A definitive answer that names no holder loses the lease after the recipe without proving who owns
# the head. The completed verdict is retained and owed, nothing is published, and the next tick
# publishes it only once a verdict of another attempt stands on the head -- in which case that one
# wins and this receipt is recorded as superseded, still never deleted.
rm -f "$fixture/steal-after-recipe"
claims_head
touch "$fixture/deny-claims-after-recipe"
results=$(non_pending)
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" != 0 ]] || fail_claims 'an unproven loss did not retain the verdict for recovery'
expect_count "$((claims_count + 5))"
[[ "$(non_pending)" == "$results" ]] || fail_claims 'a result was published after an unproven loss'
! grep -q 'abandoning attempt' "$fixture/runner.log" || fail_claims 'a finished verdict was abandoned on an unproven loss'
receipt="$fixture/runner/attempts/acme-fixture-$head/last-result.json"
jq -e '.terminal and .outcome=="success" and .recovery_required!=null
       and .publication.ownership=="unknown" and (.publication.required_status|not)' "$receipt" >/dev/null \
  || fail_claims 'an unproven loss did not record the verdict as owed with unknown ownership'
# Another host took the expired lease and published its own verdict for the head. Recovery must defer
# to it: publish nothing, and record this receipt as superseded rather than overwrite a newer result.
rm -f "$fixture/deny-claims-after-recipe" "$fixture/claims-denied" "$claim"
jq -nc --argjson clock "$(( $(wc -l <"$fixture/statuses.jsonl") + 1000 ))" --arg sha "$head" \
  '{id:"other-host",context:"fixture/required",state:"failure",sha:$sha,updated_at:$clock,
    creator:{login:"runner-bot"},
    description:"pr-gate-runner@gate-b operator-unsealed failure; exit 1; attempt other-host-attempt"}' \
  >>"$fixture/statuses.jsonl"
owed_attempt=$(jq -r '.id' "$receipt")
invoke --repo acme/fixture --pr 1
jq -e '.recovery_required==null and (.publication.required_status|not)
       and (.publication.superseded_by|test("newer verdict"))' \
  "$fixture/runner/attempts/acme-fixture-$head/$owed_attempt/receipt.json" >/dev/null \
  || fail_claims 'recovery did not record the newer verdict as superseding the owed one'
# Its own `pending` is on the head; no verdict of it ever is.
jq -se --arg a "attempt $owed_attempt" \
  'all(.[]; .state == "pending" or ((.description // "") | contains($a) | not))' \
  "$fixture/statuses.jsonl" >/dev/null \
  || fail_claims 'the owed attempt published over a newer verdict from another holder'
# The other holder reported a failure, so the head is gated afresh -- under its own new lease, as a
# new attempt with its own verdict. The owed one stays discharged and unpublished.
expect_count "$((claims_count + 6))"
grep -q 'a newer verdict stands on its head, published while this attempt held no lease' "$fixture/runner.log" \
  || fail_claims 'recovery did not report the newer verdict it yielded to'
printf 'PASS gate claims: an unproven loss owes its real verdict and yields to a newer one\n'

# An answer that never names a holder must not hold the head for ever: recovery stays fail-closed for
# a bounded number of ticks, then keeps the receipt for a person and lets the head be gated again.
claims_head
touch "$fixture/deny-claims-after-recipe"
results=$(non_pending)
PR_GATE_RECOVERY_ATTEMPTS=2 invoke --repo acme/fixture --pr 1
[[ "$runner_exit" != 0 ]] || fail_claims 'the bounded-recovery gate published without a lease'
expect_count "$((claims_count + 7))"
owed_attempt=$(jq -r '.id' "$fixture/runner/attempts/acme-fixture-$head/last-result.json")
receipt="$fixture/runner/attempts/acme-fixture-$head/$owed_attempt/receipt.json"
for tick in 1 2; do
  PR_GATE_RECOVERY_ATTEMPTS=2 invoke --repo acme/fixture --pr 1
  grep -q 'recovery required for' "$fixture/runner.log" \
    || fail_claims "recovery tick $tick gave up before its bound"
done
jq -e '.publication.recovery_deferred==null' "$receipt" >/dev/null \
  || fail_claims 'recovery was deferred before its bound'
PR_GATE_RECOVERY_ATTEMPTS=2 invoke --repo acme/fixture --pr 1
jq -e '.publication.recovery_deferred==true and .recovery_required!=null and .outcome=="success"
       and (.publication.required_status|not)' "$receipt" >/dev/null \
  || fail_claims 'a permanently unproven ownership was not deferred with its receipt kept'
! grep -q 'recovery required for' "$fixture/runner.log" \
  || fail_claims 'the deferred receipt still held its head in recovery'
[[ "$(non_pending)" == "$results" ]] || fail_claims 'the deferred receipt was published without a lease'
expect_count "$((claims_count + 7))"
rm -f "$fixture/deny-claims-after-recipe" "$fixture/claims-denied" "$claim"
printf 'PASS gate claims: an ownership that stays unknown is deferred after a bounded recovery\n'

# A lease lost while the recipe runs stops the recipe: the slot does not spend the rest of a gate on
# a head another host now gates, and publishes nothing for it.
claims_head
printf '30\n' >"$fixture/claim-ttl"
printf '25\n' >"$fixture/recipe-sleep"
touch "$fixture/steal-on-renew"
results=$(non_pending)
started=$(date +%s)
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || fail_claims 'a lease lost mid-recipe failed the runner'
(( $(date +%s) - started < 24 )) || fail_claims 'the recipe ran on after its lease was lost'
[[ "$(non_pending)" == "$results" ]] || fail_claims 'a result was published after the lease was lost mid-recipe'
grep -q 'abandoning attempt' "$fixture/runner.log" || fail_claims 'the mid-recipe loss was not reported'
grep -qE 'renewal answered|publication renewal refused' "$fixture/runner/cache/gate-claim-slot0/lost" \
  || fail_claims 'the renewal loss that stopped the recipe was not recorded'
rm -f "$fixture/steal-on-renew" "$claim"
printf 'PASS gate claims: a lease lost mid-recipe stops the recipe and publishes nothing\n'

# A slot killed outright (kill -9) leaves no process renewing its head: the renewer ends with the
# runner, so the lease lapses within one TTL and another host can take the head.
printf '20\n' >"$fixture/recipe-sleep"
"${runner_env[@]}" bash "$script_dir/pr-gate-runner.sh" --repo acme/fixture --pr 1 >"$fixture/runner.log" 2>&1 &
killed=$!
for _ in $(seq 100); do grep -q 'gate claim held for' "$fixture/runner.log" && break; sleep 0.2; done
grep -q 'gate claim held for' "$fixture/runner.log" || fail_claims 'the killed slot never took the lease'
kill -9 "$killed"; wait "$killed" 2>/dev/null || true
grants=$(grep -c "acme/fixture $head " "$fixture/claims-granted.log")
sleep 15
[[ "$(grep -c "acme/fixture $head " "$fixture/claims-granted.log")" == "$grants" ]] \
  || fail_claims 'a renewer outlived its killed runner'
sleep 8   # the orphaned recipe finishes; nothing of the slot renews its lease
rm -f "$fixture/recipe-sleep" "$fixture/claim-ttl"
printf 'PASS gate claims: a killed slot leaves no renewer behind\n'

# A handover after the first recipe must leave later candidates eligible in this tick.
claims_head
first=$head
"$real_git" -C "$fixture/source" checkout -q -b handover-second
printf 'remaining candidate\n' >>"$fixture/source/claims-marker"
"$real_git" -C "$fixture/source" commit -qam 'remaining candidate'
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" handover-second
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head2"
second=$(cat "$fixture/head2")
"$real_git" -C "$fixture/source" checkout -q main
printf '%s\n' "$first" >"$fixture/steal-after-recipe"
before_count=$(count)
invoke
[[ "$runner_exit" == 0 ]] || fail_claims 'handover failed the service'
expect_count "$((before_count + 2))"
jq -e '.outcome=="success" and .recovery_required!=null and (.publication.required_status|not)' \
  "$fixture/runner/attempts/acme-fixture-$first/last-result.json" >/dev/null
jq -se --arg sha "$first" '[.[] | select(.sha==$sha and .state!="pending")] | length==0' "$fixture/statuses.jsonl" >/dev/null
jq -se --arg sha "$second" 'any(.[]; .sha==$sha and .state=="success")' "$fixture/statuses.jsonl" >/dev/null
rm -f "$fixture/head2" "$fixture/steal-after-recipe"
printf 'PASS publication handover retains the first verdict and gates the remaining candidate\n'
