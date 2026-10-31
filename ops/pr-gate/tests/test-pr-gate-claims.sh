#!/usr/bin/env bash
# Deterministic publication authority tests; no sleeps, network or real forge credentials.
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|JERYU_|PR_GATE_)' || true)
here=$(cd "$(dirname "$0")/../bin" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
HOME_DIR="$scratch/state" SLOT=0 RUNNER_HOST=gate-a MARKER=fixture
mkdir -p "$HOME_DIR/cache"
AUTH_CONFIG="$scratch/auth" BASE=https://forge.invalid
STATUS_ATTEMPTS=2 STATUS_RETRY_SLEEP=0 PROOF_BASE_WAIT_CAP=1
owner=acme repo=fixture number=12 qref=- cbase=main list=0
sha=0123456789012345678901234567890123456789
source "$here/pr-gate-state.sh"
source "$here/pr-gate-progress.sh"
source "$here/pr-gate-claims.sh"
# Load the production transport and early-publication functions, without running the dispatcher.
for fn in api post_status proof_base_wait retire_stale_base_green; do
  eval "$(sed -n "/^$fn() {/,/^}/p" "$here/pr-gate-runner.sh")"
done
say() { printf '%s\n' "$*" >>"$scratch/operator.log"; }
die() { say "$*"; exit 1; }
heartbeat() { :; }
backoff_remaining() { echo 0; }
backoff_clear() { :; }
backoff_note_429() { :; }
# No background timing: keep the production start/stop (including lost-marker cleanup).
gate_claim_renew_loop() { :; }
owner_proof_base_var() { pb_var=ACME_PROOF_BASE_REF; }
resolve_proof_base() { pb_branch=release; }
gate_newest_is_own_success() { return 0; }
proof_base_count() { echo 1; }
curl() {
  local method=GET path payload='' count
  while (($#)); do
    case "$1" in
      -X) method=$2; shift 2;;
      --data) payload=$2; shift 2;;
      --config|-H|--max-time|--dump-header|-w) shift 2;;
      --silent|--show-error) shift;;
      *) path=${1#https://forge.invalid}; shift;;
    esac
  done
  if [[ "$path" == /api/v1/gate-claims ]]; then
    count=$(cat "$scratch/asks" 2>/dev/null || echo 0)
    echo "$((count + 1))" >"$scratch/asks"
    case "$(cat "$scratch/mode")" in
      denied) printf '{}\n409'; return;;
      lost) if ((count > 0)); then printf '{}\n409'; return; fi;;
      outage) printf '{}\n503'; return;;
      forbidden) printf '{}\n403'; return;;
      missing) printf '{"code":"api_route_not_found"}\n404'; return;;
    esac
    printf '%s\n' "$payload" >>"$scratch/grants"
    printf '{"ttl_seconds":180}\n201'
  elif [[ "$path" == /api/v1/gate-claims/release ]]; then
    printf '{}\n200'
  elif [[ "$method" == GET ]]; then
    if [[ -s "$scratch/status.json" ]]; then printf '%s\n200' "$(cat "$scratch/status.json")"; return; fi
    printf '{"statuses":[{"state":"success","description":"old","context":"fixture/required"}]}\n200'
  else
    printf '%s %s %s\n' "$method" "$path" "$payload" >>"$scratch/writes"
    printf '{"id":"ack"}\n201'
  fi
}
reset_claim() {
  gate_claim_release
  GATE_CLAIM_ROUTE=1 GATE_CLAIM_HELD=0 GATE_CLAIM_OWNER='' GATE_CLAIM_REPO='' GATE_CLAIM_SHA=''
  rm -f "$scratch/asks" "$scratch/writes" "$scratch/grants" "$scratch/status.json" \
    "$GATE_CLAIM_STATE/lost" "$GATE_CLAIM_STATE/lost-kind"
  printf '%s\n' "$1" >"$scratch/mode"
}
no_writes() { [[ ! -s "$scratch/writes" ]] || { cat "$scratch/writes" >&2; exit 1; }; }
identity="$scratch/inputs.json"
printf '{"source":"%s"}\n' "$sha" >"$identity"
gate_lock "acme-fixture-$sha"
for mode in denied lost missing; do
  for route in stale-green proof-wait canonical-main dependency-main missing-recipe; do
    reset_claim "$mode"
    case "$route" in
      stale-green) retire_stale_base_green "$owner" "$repo" "$sha" release;;
      proof-wait) proof_base_wait "$owner" "$repo" "$sha" resolve unavailable;;
      canonical-main) post_status "$owner" "$repo" "$sha" failure 'no canonical main to gate against';;
      dependency-main) post_status "$owner" "$repo" "$sha" failure 'declared dependency has no canonical main';;
      missing-recipe) post_status "$owner" "$repo" "$sha" failure 'no gate recipe';;
    esac
    no_writes
    printf 'PASS %s %s publishes nothing\n' "$route" "$mode"
  done
  for route in head-recovery tier-recovery republish; do
    reset_claim "$mode"
    gate_begin "$identity"
    gate_finish success 0 ''
    receipt=$gate_receipt
    if [[ "$route" == republish ]]; then gate_publish && exit 1
    else gate_recover && exit 1; fi
    no_writes
    jq -e '.terminal and .outcome=="success" and .recovery_required!=null and (.publication.required_status|not)' "$receipt" >/dev/null
    gate_receipt=''
    printf 'PASS %s %s retains unpublished verdict\n' "$route" "$mode"
  done
  reset_claim "$mode"
  gate_begin "$identity"
  receipt=$gate_receipt
  # gate_exit checks BASHPID == $$, so exercise it in its own Bash process, not a subshell.
  export HOME_DIR SLOT RUNNER_HOST MARKER AUTH_CONFIG BASE STATUS_ATTEMPTS STATUS_RETRY_SLEEP
  export owner repo number qref sha scratch gate_key_dir gate_receipt GATE_CLAIM_STATE GATE_CLAIM_ROUTE GATE_CLAIM_HELD
  export GATE_CLAIM_OWNER GATE_CLAIM_REPO GATE_CLAIM_NUMBER GATE_CLAIM_SHA GATE_CLAIM_FIELD GATE_CLAIM_TTL gate_claim_renewer
  export -f api curl say heartbeat backoff_remaining backoff_clear backoff_note_429
  bash -c 'source "$1/pr-gate-state.sh"; source "$1/pr-gate-progress.sh"; source "$1/pr-gate-claims.sh"; gate_claim_renew_loop() { :; }; trap gate_exit EXIT' _ "$here"
  no_writes
  jq -e '.terminal and .outcome=="interrupted" and .recovery_required!=null' "$receipt" >/dev/null
  gate_receipt=''
  printf 'PASS exit %s retains interrupted verdict without publication\n' "$mode"
done
# Completed results survive an outage and recover without a new recipe/attempt.
reset_claim granted
gate_begin "$identity"
gate_finish success 0 ''
receipt=$gate_receipt
# Already hold a lease; its pre-publication renewal now cannot reach the forge.
gate_claim_take "$owner" "$repo" "$number" "$sha"
printf 'outage\n' >"$scratch/mode"
if gate_publish; then exit 1; fi
no_writes
jq -e '.outcome=="success" and .publication.superseded_by==null and .recovery_required!=null' "$receipt" >/dev/null
printf 'granted\n' >"$scratch/mode"
gate_recover
[[ $(wc -l <"$scratch/writes") == 2 ]]
jq -e '.publication.required_status and .publication.check_run and .recovery_required==null' "$receipt" >/dev/null
printf 'PASS renewal outage recovers the saved verdict with no new attempt\n'
# The renewer can record a loss before the foreground publication check runs.
# Exercise that ordering without sleeps: retain the completed result, report why
# it cannot be published, and recover it only after a fresh grant clears the loss.
reset_claim granted
gate_begin "$identity"; gate_finish success 0 ''
receipt=$gate_receipt
gate_claim_take "$owner" "$repo" "$number" "$sha"
asks_before=$(cat "$scratch/asks")
printf 'renewal answered 409: fixture-private-detail\n' >"$GATE_CLAIM_STATE/lost"
if gate_publish; then exit 1; fi
no_writes
[[ $(cat "$scratch/asks") == "$asks_before" ]]
grep -Fq 'publication lease was lost; posting nothing' "$scratch/operator.log"
if grep -Fq 'fixture-private-detail' "$scratch/operator.log"; then
  printf 'lost-marker contents reached the operator log\n' >&2; exit 1
fi
jq -e '.terminal and .outcome=="success" and .recovery_required!=null and (.publication.required_status|not)' "$receipt" >/dev/null
gate_claim_release
gate_recover
[[ $(wc -l <"$scratch/writes") == 2 ]]
jq -e '.publication.required_status and .publication.check_run and .recovery_required==null' "$receipt" >/dev/null
printf 'PASS a recorded renewal loss is reported and recovery requires a fresh lease\n'
# Verify immediately before BOTH writes, never only once at gate_publish entry.
reset_claim granted
gate_begin "$identity"; gate_finish success 0 ''
gate_update '.publication.required_status=true'
printf 'denied\n' >"$scratch/mode"
gate_publish
no_writes
printf 'PASS a missing check run needs its own live lease\n'
reset_claim granted
gate_claim_take "$owner" "$repo" "$number" "$sha"
printf 'old loss\n' >"$GATE_CLAIM_STATE/lost"
gate_claim_take "$owner" "$repo" "$number" "$sha"
[[ ! -f "$GATE_CLAIM_STATE/lost" ]]
printf 'PASS a regrant removes the old lost marker\n'
# A publication-time refusal stops an already registered recipe immediately,
# without waiting for the background renewal interval. Record the signal rather
# than using wall-clock deadlines or leaving test processes behind.
reset_claim granted
gate_claim_take "$owner" "$repo" "$number" "$sha"
printf '1234\n' >"$GATE_CLAIM_STATE/worker"
printf 'denied\n' >"$scratch/mode"
kill() { printf '%s\n' "$*" >>"$scratch/signals"; }
api POST "/repos/$owner/$repo/statuses/$sha" '{"state":"success"}'
no_writes
grep -qx -- '-TERM -- -1234' "$scratch/signals"
# If the background renewer lost the lease before the parent could register
# the process group, registration must notice the existing loss and stop it.
rm -f "$GATE_CLAIM_STATE/worker" "$scratch/signals"
gate_claim_track_worker 5678
grep -qx -- '-TERM -- -5678' "$scratch/signals"
unset -f kill
rm -f "$GATE_CLAIM_STATE/worker"
printf 'PASS publication renewal loss and pre-registration loss stop the worker immediately\n'
# queue_sha is reserved for actual queue refs; main/branch health is a head claim.
for qref in refs/heads/main refs/heads/release refs/queue/main/12; do
  reset_claim granted
  post_status "$owner" "$repo" "$sha" pending test
  if [[ "$qref" == refs/queue/* ]]; then field=queue_sha; else field=head_sha; fi
  jq -se --arg field "$field" 'all(.[]; has($field))' "$scratch/grants" >/dev/null
done
printf 'PASS branch/health and queue claims use the correct head field\n'
# What an abandoned attempt owes follows from the ownership its loss proves, and from whether the
# recipe had produced a verdict at all. The ownership is state the renewer records, not marker text.
lose_claim() { # kind why
  printf '%s\n' "$1" >"$GATE_CLAIM_STATE/lost-kind"
  printf '%s\n' "$2" >"$GATE_CLAIM_STATE/lost"
}
reset_claim granted
gate_begin "$identity"; gate_finish failure 1 ''
receipt=$gate_receipt
gate_claim_take "$owner" "$repo" "$number" "$sha"
lose_claim unknown 'renewal answered 503, 200s after the last renewal'
gate_claim_abandon "$(gate_claim_lost)"
jq -e '.outcome=="failure" and .publication.superseded_by==null and .publication.ownership=="unknown"
       and (.recovery_required|test("ownership unknown"))' "$receipt" >/dev/null
no_writes
printf 'PASS an unproven loss keeps the real failed receipt owed for recovery\n'
# An attempt the loss interrupted has no verdict: a host that does not hold the head must not invent
# one, so nothing is owed and the head is simply gated again.
reset_claim granted
gate_begin "$identity"
receipt=$gate_receipt
gate_claim_take "$owner" "$repo" "$number" "$sha"
lose_claim unknown 'renewal answered 500, 300s after the last renewal'
gate_claim_abandon "$(gate_claim_lost)"
jq -e '.terminal and .outcome=="claim_lost" and .publication.superseded_by!=null
       and .publication.ownership==null and .recovery_required==null' "$receipt" >/dev/null
no_writes
gate_receipt=''
printf 'PASS an unproven loss of an unfinished attempt owes nothing and publishes nothing\n'
reset_claim granted
gate_begin "$identity"; gate_finish failure 1 ''
receipt=$gate_receipt
gate_claim_take "$owner" "$repo" "$number" "$sha"
lose_claim refused 'renewal answered 409'
gate_claim_abandon "$(gate_claim_lost)"
jq -e '.outcome=="failure" and .publication.superseded_by!=null and .recovery_required==null' "$receipt" >/dev/null
no_writes
printf 'PASS a refused renewal records the other holder, owing nothing\n'
# A marker left by a runner that recorded no ownership keeps the meaning it was written with.
reset_claim granted
gate_claim_take "$owner" "$repo" "$number" "$sha"
printf 'renewal answered 409: fixture-private-detail\n' >"$GATE_CLAIM_STATE/lost"
[[ "$(gate_claim_lost_kind)" == refused ]]
printf 'renewal answered 403, 400s after the last renewal\n' >"$GATE_CLAIM_STATE/lost"
[[ "$(gate_claim_lost_kind)" == unknown ]]
printf 'PASS a marker written without recorded ownership is classified from its own answer\n'
# After a long cache upload the lease is asked again: a definitive answer is recorded with the
# ownership it proves, and an outage is not recorded at all.
for mode in outage denied forbidden; do
  reset_claim granted
  gate_claim_take "$owner" "$repo" "$number" "$sha"
  printf '%s\n' "$mode" >"$scratch/mode"
  gate_claim_recheck
  case "$mode" in
    outage) [[ ! -f "$GATE_CLAIM_STATE/lost" ]];;
    denied) [[ "$(gate_claim_lost_kind)" == refused ]];;
    forbidden) [[ "$(gate_claim_lost_kind)" == unknown ]];;
  esac
done
printf 'PASS the post-upload recheck records the ownership each answer proves\n'
# Recovery of a verdict owed while ownership was unknown: a verdict posted after this attempt
# finished, by anything but this attempt, is another holder's and is never published over.
reset_claim granted
gate_begin "$identity"; gate_finish failure 1 ''
receipt=$gate_receipt
gate_claim_take "$owner" "$repo" "$number" "$sha"
lose_claim unknown 'renewal answered 503, 200s after the last renewal'
gate_claim_abandon "$(gate_claim_lost)"
printf 'granted\n' >"$scratch/mode"
IDENTITY=gate-user
# This attempt's own `pending` is on the head, and a terminal verdict of another attempt follows it.
jq -nc --arg mine "pr-gate-runner@gate-a operator-unsealed required running; attempt $(jq -r .id "$receipt")" \
  '{statuses:[{state:"pending",context:"fixture/required",description:$mine,
               creator:{login:"gate-user"},updated_at:1},
              {state:"success",context:"fixture/required",creator:{login:"gate-user"},updated_at:2,
               description:"pr-gate-runner@gate-b operator-unsealed success; exit 0; attempt other-host"}]}' \
  >"$scratch/status.json"
gate_recover
no_writes
jq -e '.outcome=="failure" and .publication.ownership==null and .recovery_required==null
       and (.publication.superseded_by|test("newer verdict"))' "$receipt" >/dev/null
printf 'PASS recovery defers to a verdict another holder published while ownership was unknown\n'
# The same receipt with nothing newer on the forge is published, under a lease taken afresh.
reset_claim granted
gate_begin "$identity"; gate_finish failure 1 ''
receipt=$gate_receipt
gate_claim_take "$owner" "$repo" "$number" "$sha"
lose_claim unknown 'renewal answered 503, 200s after the last renewal'
gate_claim_abandon "$(gate_claim_lost)"
printf 'granted\n' >"$scratch/mode"
# An earlier attempt's verdict precedes this attempt's own `pending`: nothing newer stands.
jq -nc --arg mine "pr-gate-runner@gate-a operator-unsealed required running; attempt $(jq -r .id "$receipt")" \
  '{statuses:[{state:"failure",context:"fixture/required",creator:{login:"gate-user"},updated_at:1,
               description:"pr-gate-runner@gate-a operator-unsealed failure; exit 1; attempt earlier"},
              {state:"pending",context:"fixture/required",description:$mine,
               creator:{login:"gate-user"},updated_at:2}]}' >"$scratch/status.json"
gate_recover
jq -e '.publication.required_status and .publication.check_run and .recovery_required==null
       and .publication.superseded_by==null' "$receipt" >/dev/null
grep -q 'failure' "$scratch/writes"
printf 'PASS recovery publishes the owed verdict under a fresh lease when no newer verdict stands\n'
# An answer that never proves ownership must not hold the head for ever: recovery stays fail-closed
# for a bounded number of ticks, then keeps the receipt, leaves it for a person and frees the head.
reset_claim granted
gate_begin "$identity"; gate_finish failure 1 ''
receipt=$gate_receipt
gate_claim_take "$owner" "$repo" "$number" "$sha"
lose_claim unknown 'renewal answered 403, 400s after the last renewal'
gate_claim_abandon "$(gate_claim_lost)"
GATE_RECOVERY_ATTEMPTS=3
printf 'forbidden\n' >"$scratch/mode"
for tick in 1 2 3; do
  if gate_recover; then printf 'recovery gave up on tick %s\n' "$tick" >&2; exit 1; fi
  gate_receipt=''
done
no_writes
jq -e '.publication.recovery_deferred==null and .recovery_required!=null' "$receipt" >/dev/null
gate_recover
no_writes
jq -e '.publication.recovery_deferred==true and .recovery_required!=null and .outcome=="failure"
       and (.publication.required_status|not)' "$receipt" >/dev/null
gate_recover
no_writes
printf 'PASS an ownership that stays unknown is deferred after a bounded number of recovery ticks\n'
unset IDENTITY
GATE_RECOVERY_ATTEMPTS=10
gate_claim_release
gate_receipt=''
