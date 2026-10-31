#!/usr/bin/env bash
# Exercise the whole controller with local Git objects and stand-in forge/model
# processes. Nothing reaches the network or a real review/merge credential.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
worker=''
finish() {
  local result=$?
  if ((result != 0)); then tail -80 "$t/controller.log" 2>/dev/null || true; fi
  if [[ -n "$worker" ]]; then kill -KILL -- "-$worker" 2>/dev/null || true; wait "$worker" 2>/dev/null || true; fi
  rm -rf -- "$t"
}
trap finish EXIT
real_git="$(command -v git)"
fixture_git() {
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_AUTHOR_DATE \
    -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL -u GIT_COMMITTER_DATE \
    "$real_git" "$@"
}
mkdir -p "$t/bin" "$t/state" "$t/repo"
printf 'fixture-bearer\n' > "$t/token"
fixture_git init -q -b main "$t/repo"
g() { fixture_git -C "$t/repo" -c user.name=fixture -c user.email=fixture@example.invalid "$@"; }
printf 'base\n' > "$t/repo/README.md"; g add .; g commit -qm base
g rev-parse HEAD > "$t/base"
cp "$t/base" "$t/initial-base"
g switch -qc topic
printf 'accepted prerequisite\n' > "$t/repo/prerequisite"; g add .; g commit -qm 'Accepted prerequisite (#35)'
g rev-parse HEAD > "$t/prerequisite"
# Unrelated main progress exceeds the PR limit but must not charge this PR.
g switch -q main
g merge --ff-only topic >/dev/null
printf '%030000d\n' 0 > "$t/repo/main-only"
g add .; g commit -qm 'Unrelated main progress'
g rev-parse HEAD > "$t/main-tip"
g switch -q topic
printf 'candidate\n' >> "$t/repo/README.md"; g commit -qam candidate
g rev-parse HEAD > "$t/head"
cat > "$t/bin/git" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  case "$arg" in
    push|rebase|--force-with-lease*) echo forbidden-history-write >> "$PUBLISH_FIXTURE/danger"; exit 97 ;;
    https://forge.invalid/git/jeryu/fixture.git) args+=("$PUBLISH_FIXTURE/repo") ;;
    *) args+=("$arg") ;;
  esac
done
exec "$FIXTURE_REAL_GIT" "${args[@]}"
FIXTURE
cat > "$t/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
method=GET data=''
while (($#)); do
  case "$1" in
    --config) [[ "$2" != - ]] || cat > /dev/null; shift ;;
    -X) method="$2"; shift ;;
    --data) data="$2"; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
printf '%s %s\n' "$method" "$url" >> "$PUBLISH_FIXTURE/requests"
row() {
  jq -nc --arg sha "$(cat "$PUBLISH_FIXTURE/head")" --arg base "$(cat "$PUBLISH_FIXTURE/base")" --arg approved "$(test ! -e "$PUBLISH_FIXTURE/forge-approved" || echo approved)" \
    --arg proof "$(if [[ ! -e "$PUBLISH_FIXTURE/with-contexts" ]]; then :; elif [[ -e "$PUBLISH_FIXTURE/gate-blocked" ]]; then echo failure; elif [[ -e "$PUBLISH_FIXTURE/gate-pending" ]]; then echo pending; else echo success; fi)" \
    '{repo:{owner:"jeryu",name:"fixture"},number:1,head_sha:$sha,base_sha:$base,head_ref:"topic",base_ref:"main",draft:false,author:"contributor",title:"fixture",body_markdown:"fixture",state:"open",labels:["origin:internal"],passport_hash:"fixture-passport",review:{user_review_state:$approved,changes_requested:0},mergeable:{can_merge:true},
      updated_at:(now|tostring),agents:{active_sessions:(now|floor % 7)},checks:{pending:(now|floor % 3)},
      required_contexts:(if $proof == "" then null else [{name:"jankurai/proof",state:$proof}] end)}
    | if .required_contexts == null then del(.required_contexts) else . end'
}
case "$url" in
  */refs)
    jq -nc --arg sha "$(cat "$PUBLISH_FIXTURE/main-tip")" '[{name:"main",kind:"branch",sha:$sha,protected:true}]'
    printf '\n200' ;;
  */branches/*/protection)
    # The base branch's enforced required contexts: this fixture's main enforces the quality proof,
    # exactly as the row reports it on the head.
    printf '{"required_status_checks":{"contexts":["jankurai/proof"]}}\n200' ;;
  */api/v3/user) printf '{"login":"independent-reviewer"}\n200' ;;
  */api/v1/repos) printf '{"repositories":[{"id":{"owner":"jeryu","name":"fixture"},"family":"jain","open_pull_requests":1}]}\n200' ;;
  *'/pulls?state=open') row | jq -c '{items:[.]}'; printf '\n200' ;;
  */pulls/1)
    # The pull request detail: its merge passport says whether the base branch
    # requires jankurai/proof on this head and whether it passes.
    if [[ -e "$PUBLISH_FIXTURE/gate-blocked" ]]; then
      printf '{"merge_passport":{"blockers":[{"code":"passport_blocked_checks","message":"Required context `jankurai/proof` is failing."}]}}\n200'
    elif [[ -e "$PUBLISH_FIXTURE/gate-pending" ]]; then
      printf '{"merge_passport":{"blockers":[{"code":"passport_blocked_checks","message":"Required context `jankurai/proof` is queued or running."}]}}\n200'
    else printf '{"merge_passport":{"blockers":[]}}\n200'; fi ;;
  */pulls/1/diff)
    # Read by the pin-wait check while a required context is pending: not a pin bump.
    jq -nc --arg sha "$(cat "$PUBLISH_FIXTURE/head")" '{head_sha:$sha,truncated:false,files:[{path:"README.md"}]}'
    printf '\n200' ;;
  */pulls/1/checks)
    if [[ -e "$PUBLISH_FIXTURE/gate-blocked" ]]; then
      printf '{"checks":[{"name":"jankurai/proof","required":true,"title":"score 47 < floor 85"}]}\n200'
    else printf '{"checks":[]}\n200'; fi ;;
  */check-runs)
    jq -c . <<< "$data" >> "$PUBLISH_FIXTURE/check-runs"; printf '{"id":"check-run-fixture"}\n201' ;;
  */pulls/1/merge)
    # Nothing in this suite ends at an approved receipt, so any landing attempt here is a bug.
    printf 'merged a head without an approving receipt\n' >> "$PUBLISH_FIXTURE/danger"; exit 99 ;;
  */reviews)
    jq -c . <<< "$data" >> "$PUBLISH_FIXTURE/posts"
    if [[ -e "$PUBLISH_FIXTURE/reject" ]]; then printf '{"message":"publication refused"}\n403'
    elif [[ "$(jq -r .expected_head_sha <<< "$data")" != "$(cat "$PUBLISH_FIXTURE/head")" ]]; then printf '{"message":"head changed"}\n409'
    else jq -c . <<< "$data" >> "$PUBLISH_FIXTURE/accepted"; printf '{"ok":true}\n201'; fi ;;
  */api/v1/repos/jeryu%2Fjeryu-tool|*/api/v1/repos/jeryu%2Fjeryu-tool/refs)
    # The governed tool authority. This fixture has no such repository: the read is recorded and
    # answered 404, so the evidence reports it instead of fetching anything.
    printf '%s\n' "$url" >> "$PUBLISH_FIXTURE/authority-reads"
    printf '{"error":{"code":"not_found"}}\n404' ;;
  */heartbeat) printf '{"accepted":true}\n200' ;;
  */api/v1/events) jq -c . <<< "$data" >> "$PUBLISH_FIXTURE/events"; printf '{"ok":true,"seqs":[1],"duplicates":0}\n201' ;;
  *) printf 'forbidden API %s\n' "$url" >> "$PUBLISH_FIXTURE/danger"; exit 98 ;;
esac
FIXTURE
cat > "$t/bin/model" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then echo '9.9.9 (Claude Code)'; exit 0; fi
PUBLISH_FIXTURE="$(dirname "$(dirname "$0")")"
printf 'called\n' >> "$PUBLISH_FIXTURE/model-calls"
touch "$PUBLISH_FIXTURE/model-started"
# Production collection reaches the model with both the retained diff and effective view.
if [[ "$(cat "$PUBLISH_FIXTURE/base")" == "$(cat "$PUBLISH_FIXTURE/initial-base")" ]]; then
grep -q "Accepted prerequisite boundary: $(cat "$PUBLISH_FIXTURE/prerequisite")" ../review/prerequisites/SUMMARY.txt
grep -q '+accepted prerequisite' ../review/diff.patch
if grep -q '+accepted prerequisite' ../review/prerequisites/effective.patch; then exit 1; fi
grep -q '+candidate' ../review/prerequisites/effective.patch
grep -q 'main-only.patch: 768 bytes; truncated=true; git_error=false' ../review/prerequisites/SUMMARY.txt
[[ "$(wc -c < ../review/diff.patch)" -lt 8192 ]]
# The production check reports the retained PR bytes, without duplicate or main-only bytes.
jq -se --arg measure "Diff: $(wc -l < ../review/files.txt) files, $(wc -c < ../review/diff.patch) bytes." \
  'any(.[]; .output.summary | contains($measure))' "$PUBLISH_FIXTURE/check-runs" >/dev/null
fi
while [[ -e "$PUBLISH_FIXTURE/gate" ]]; do sleep 0.05; done
# The proof gets its (failing) result while the agent runs.
if [[ -e "$PUBLISH_FIXTURE/model-turns-red" ]]; then rm -f "$PUBLISH_FIXTURE/gate-pending"; touch "$PUBLISH_FIXTURE/gate-blocked"; fi
if [[ -e "$PUBLISH_FIXTURE/model-fail" ]]; then exit 42; fi
if [[ -e "$PUBLISH_FIXTURE/model-leak" ]]; then
  jq -nc --arg secret "$(cat "$PUBLISH_FIXTURE/token")" \
    '{type:"result",subtype:"success",is_error:false,structured_output:{verdict:"approve",summary:$secret,findings:[]}}'
elif [[ -e "$PUBLISH_FIXTURE/model-cost" ]]; then
  # What the real CLI adds to its result: the session's dollars, per model by token class.
  printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.4321,"modelUsage":{"model-x[1m]":{"canonicalModel":"model-x","inputTokens":12,"outputTokens":3400,"cacheReadInputTokens":250000,"cacheCreationInputTokens":9000,"thinkingTokens":800,"costUSD":0.4321}},"structured_output":%s}\n' "$(cat "$PUBLISH_FIXTURE/verdict")"
else
  printf '{"type":"result","subtype":"success","is_error":false,"structured_output":%s}\n' "$(cat "$PUBLISH_FIXTURE/verdict")"
fi
FIXTURE
chmod +x "$t/bin/"*
printf '{"verdict":"approve","summary":"fixture review complete","findings":[]}\n' > "$t/verdict"
export PUBLISH_FIXTURE="$t" FIXTURE_REAL_GIT="$real_git"
export PATH="$t/bin:$PATH" JERYU_TOKEN_FILE="$t/token" REDTEAM_MERGE_TOKEN_FILE="$t/token"
export REDTEAM_STATE="$t/state" REDTEAM_CLAUDE="$t/bin/model" REDTEAM_CLAUDE_VERSION=9.9.9 REDTEAM_TIMEOUT=10
export JERYU_BASE=https://forge.invalid
# This suite publishes holds on head after head; the hold cap is hold-cap.sh's subject, not this one's.
export REDTEAM_HOLD_CAP=0 REDTEAM_MAX_DIFF_BYTES=8192
# Exercise publication after the admission wait expires; pin-wait.sh covers admission itself.
export REDTEAM_GATE_WAIT_SECS=0
review() { "$here/pr-redteam" _review 0 0 0 jeryu/fixture 1 >> "$t/controller.log" 2>&1; }
receipt() { printf '%s/state/receipts/jeryu/fixture/1-%s.json\n' "$t" "$(cat "$t/head")"; }
count() { if [[ -f "$1" ]]; then wc -l < "$1"; else echo 0; fi; }
advance() { printf 'next\n' >> "$t/repo/README.md"; g commit -qam next; g rev-parse HEAD > "$t/head"; }
# A loaded gate host can take well over 10 s to start the worker; 60 s still bounds a real hang.
wait_model() { for ((i=0;i<1200;i++)); do [[ ! -e "$t/model-started" ]] || return 0; sleep 0.05; done; echo 'model did not start within 60s' >&2; return 1; }

# Rejected publication is durable and retryable; a restart can publish once.
touch "$t/reject"
review
jq -e '.posted == false and .decision == "publication_rejected" and .post_http == "403"' "$(receipt)" > /dev/null
jq -se 'map(select(.name == "pr-redteam/review" and .head_sha == $head)) | any(.status == "in_progress") and any(.status == "completed" and .conclusion == "failure")' \
  --arg head "$(cat "$t/head")" "$t/check-runs" > /dev/null
[[ "$(count "$t/accepted")" == 0 ]]
rm "$t/reject"
review
jq -e '.posted == true and .decision == "approve"' "$(receipt)" > /dev/null
jq -se 'map(select(.name == "pr-redteam/review" and .head_sha == $head)) | any(.status == "completed" and .conclusion == "success" and (.output.summary | contains("Reviewer:")) and (.output.summary | contains("Diff:")))' \
  --arg head "$(cat "$t/head")" "$t/check-runs" > /dev/null
[[ "$(count "$t/accepted")" == 1 ]]
review
[[ "$(count "$t/accepted")" == 1 && "$(count "$t/model-calls")" == 2 ]]
echo 'ok rejected publication, restart, duplicate dispatch'

# Changed heads need a new model verdict, even after previous approval.
advance
review
[[ "$(count "$t/accepted")" == 2 && "$(count "$t/model-calls")" == 3 ]]
echo 'ok changed head re-reviewed'

# A real worker process killed with its children leaves a visible recoverable claim.
advance
rm -f "$t/model-started"
touch "$t/gate"
setsid "$here/pr-redteam" _review 0 0 0 jeryu/fixture 1 >> "$t/controller.log" 2>&1 & worker=$!
wait_model
[[ "$(ps -o pgid= -p "$worker" | tr -d ' ')" == "$worker" ]]
jq -e '.decision == "reviewing" and .posted == false' "$(receipt)" > /dev/null
review
[[ "$(count "$t/model-calls")" == 4 ]]
kill -KILL -- "-$worker"
wait "$worker" 2>/dev/null || true
worker=''
# The model timeout has its own process group. Its bounded termination must
# release the inherited lock before another worker is admitted.
flock -w 15 "$t/state/locks/jeryu_fixture-1.lock" true
rm "$t/gate"
review
jq -es 'any(.[]; .decision == "interrupted" and .posted == false)' "$t/state/attempts/jeryu/fixture/"*.json > /dev/null
[[ "$(count "$t/accepted")" == 3 ]]
echo 'ok concurrent dispatch excluded, killed worker claim recovered'

# A head that moves during review refuses publication; the replacement is reviewed.
advance
rm -f "$t/model-started"
touch "$t/gate"
setsid "$here/pr-redteam" _review 0 0 0 jeryu/fixture 1 >> "$t/controller.log" 2>&1 & worker=$!
wait_model
prior_receipt="$(receipt)"
advance
rm "$t/gate"
wait "$worker"; worker=''
jq -e '.decision == "publication_rejected" and .post_http == "409" and .posted == false' "$prior_receipt" > /dev/null
[[ "$(count "$t/accepted")" == 3 ]]
review
[[ "$(count "$t/accepted")" == 4 ]]
echo 'ok in-flight changed head rejected, successor re-reviewed'

advance
touch "$t/model-fail"
review
jq -e '.decision == "failed" and .posted == false' "$(receipt)" > /dev/null
rm "$t/model-fail"
posts_before="$(count "$t/posts")"
touch "$t/model-leak"
review
jq -e '.decision == "failed" and .posted == false' "$(receipt)" > /dev/null
[[ "$(count "$t/posts")" == "$posts_before" ]]
if grep -RFq 'fixture-bearer' "$t/state" "$t/controller.log"; then echo 'forbidden credential or activation evidence' >&2; exit 1; fi
rm "$t/model-leak"
echo 'ok credential-bearing result never published or stored as a review'

printf '{"verdict":"block","summary":"evidence incomplete","findings":[]}\n' > "$t/verdict"
review
jq -e '.posted == true and .decision == "hold"' "$(receipt)" > /dev/null
tail -1 "$t/accepted" | jq -e '.verdict == "request_changes"' > /dev/null
echo 'ok failed model terminal receipt, explicit hold published'

# Reuse requires matching implementation/model inputs, even if the forge still
# says that this actor approved the unchanged head under the previous policy.
old_identity="$(jq -r .review_identity "$(receipt)")"
model_calls="$(count "$t/model-calls")"
touch "$t/forge-approved"
REDTEAM_MODEL=fixture-requalification review
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" ]]
jq -e --arg prior "$old_identity" '.review_identity != $prior and .posted == true' "$(receipt)" > /dev/null
export REDTEAM_MODEL=fixture-requalification
echo 'ok changed review identity invalidates cached approval'

# Changing the actual CLI bytes while a review runs invalidates that attempt.
advance
rm -f "$t/model-started"
touch "$t/gate"
setsid "$here/pr-redteam" _review 0 0 0 jeryu/fixture 1 >> "$t/controller.log" 2>&1 & worker=$!
wait_model
accepted_before="$(count "$t/accepted")"
printf '\n# replacement CLI fixture\n' >> "$t/bin/model"
rm "$t/gate"
wait "$worker"; worker=''
jq -e '.decision == "failed" and .posted == false' "$(receipt)" > /dev/null
[[ "$(count "$t/accepted")" == "$accepted_before" ]]
review
[[ "$(count "$t/accepted")" == "$((accepted_before + 1))" ]]
echo 'ok changing tool input rejects in-flight publication'

# Deterministic size holds reuse only matching policy; changed limits requalify.
advance
model_calls="$(count "$t/model-calls")"
REDTEAM_MAX_DIFF_BYTES=1 review
jq -e '.decision == "too_large" and .posted == false and (.review_identity | length == 64)' "$(receipt)" > /dev/null
attempts="$(find "$t/state/attempts" -type f | wc -l)"
REDTEAM_MAX_DIFF_BYTES=1 review
[[ "$(find "$t/state/attempts" -type f | wc -l)" == "$attempts" ]]
[[ "$(count "$t/model-calls")" == "$model_calls" ]]
review
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" ]]
echo 'ok deterministic size hold reused, changed policy requalified'

# A repository restricted to one email domain holds other commits before the model runs, once per
# head; a matching domain (any case) is reviewed, and a lookalike domain is not a match.
advance
model_calls="$(count "$t/model-calls")"; accepted_before="$(count "$t/accepted")"
REDTEAM_AUTHOR_DOMAINS='other/repo=example.invalid jeryu/fixture=veox.example' review
jq -e '.decision == "author_domain" and .posted == false and .author_domain == "veox.example"
  and .foreign_emails == ["fixture@example.invalid"]' "$(receipt)" > /dev/null
attempts="$(find "$t/state/attempts" -type f | wc -l)"
REDTEAM_AUTHOR_DOMAINS='other/repo=example.invalid jeryu/fixture=veox.example' review
[[ "$(find "$t/state/attempts" -type f | wc -l)" == "$attempts" ]]
[[ "$(count "$t/model-calls")" == "$model_calls" && "$(count "$t/accepted")" == "$accepted_before" ]]
REDTEAM_AUTHOR_DOMAINS='jeryu/fixture=EXAMPLE.invalid' review
jq -e '.decision != "author_domain" and .posted == true' "$(receipt)" > /dev/null
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" ]]
printf 'outsider\n' >> "$t/repo/README.md"
fixture_git -C "$t/repo" -c user.name=outsider -c user.email=x@notexample.invalid commit -qam outsider
g rev-parse HEAD > "$t/head"
REDTEAM_AUTHOR_DOMAINS='jeryu/fixture=example.invalid' review
jq -e '.decision == "author_domain" and .foreign_emails == ["x@notexample.invalid"]' "$(receipt)" > /dev/null
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" ]]
echo 'ok author domain held before the model, matching domain reviewed'

# Git's own placeholder identity holds the head in every repository, with no domain configured, once
# per head and before the model runs: the log of the commit a maintainer approves says nothing.
model_calls="$(count "$t/model-calls")"; accepted_before="$(count "$t/accepted")"
named_head="$(cat "$t/head")"
printf 'unsigned\n' >> "$t/repo/README.md"
# The same commit moves the generated governed tool version, so this head is one the governed
# evidence would gather the authority for -- had it not been held first.
mkdir -p "$t/repo/agent"
printf 'minimum_score = 85\nrequired_tool_version = "1.7.6"\n' > "$t/repo/agent/audit-policy.toml"
fixture_git -C "$t/repo" add agent/audit-policy.toml
authority_reads="$(count "$t/authority-reads")"
fixture_git -C "$t/repo" -c 'user.name=Your Name' -c user.email=you@example.com commit -qam placeholder
g rev-parse HEAD > "$t/head"
review
jq -e '.decision == "placeholder_author" and .posted == false
  and (.placeholder_commits | length == 1)
  and (.placeholder_commits[0] | endswith("Your Name <you@example.com>"))' "$(receipt)" > /dev/null
attempts="$(find "$t/state/attempts" -type f | wc -l)"
review
[[ "$(find "$t/state/attempts" -type f | wc -l)" == "$attempts" ]]
[[ "$(count "$t/model-calls")" == "$model_calls" && "$(count "$t/accepted")" == "$accepted_before" ]]
# A head the controller holds mechanically is never shown to the agent, so its governed authority is
# never read: no forge request for it, on this review or on the repeat above.
[[ "$(count "$t/authority-reads")" == "$authority_reads" ]]
# A head whose commits all name a person is reviewed as usual -- and then the same governed move does
# cost the authority its reads, so the assertion above is about the hold and not about the move.
g reset -q --hard "$named_head"; g rev-parse HEAD > "$t/head"
advance
review
jq -e '.decision != "placeholder_author" and .posted == true' "$(receipt)" > /dev/null
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" ]]
[[ "$(count "$t/authority-reads")" == "$authority_reads" ]]
mkdir -p "$t/repo/agent"
printf 'minimum_score = 85\nrequired_tool_version = "1.7.6"\n' > "$t/repo/agent/audit-policy.toml"
g add agent/audit-policy.toml; g commit -qm 'render the governed version'; g rev-parse HEAD > "$t/head"
review
jq -e '.posted == true' "$(receipt)" > /dev/null
[[ "$(count "$t/authority-reads")" -gt "$authority_reads" ]]
g rm -q agent/audit-policy.toml; g commit -qm 'drop the fixture policy'; g rev-parse HEAD > "$t/head"
echo 'ok a placeholder commit identity holds before the model, with no domain configured'
echo 'ok a mechanically held head costs the governed authority no read; a reviewed move does'

# A new base also invalidates the previous exact-head review receipt.
model_calls="$(count "$t/model-calls")"
g branch -f main "$(cat "$t/head")"
cat "$t/head" > "$t/base"
review
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" ]]
jq -e --arg base "$(cat "$t/base")" '.base_sha == $base and .posted == true' "$(receipt)" > /dev/null
echo 'ok changed base re-reviewed'

# A forge base_sha that is not fetchable diffs against the base branch, but the receipt stays keyed
# on the forge's value: the unchanged head is not reviewed or approved a second time.
advance
printf '%040d\n' 7 > "$t/base"
model_calls="$(count "$t/model-calls")"; accepted_before="$(count "$t/accepted")"
review
jq -e --arg base "$(cat "$t/base")" '.base_sha == $base and .diff_base_sha != $base and .posted == true' "$(receipt)" > /dev/null
review
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" && "$(count "$t/accepted")" == "$((accepted_before + 1))" ]]
echo 'ok unfetchable forge base approved once'

# The quality gate: where the base branch requires jankurai/proof, a head whose
# proof fails is held with that reason and no review budget is spent on it —
# an approving agent could not have approved it anyway.
advance
printf '{"verdict":"approve","summary":"fixture review complete","findings":[]}\n' > "$t/verdict"
touch "$t/gate-blocked"
model_calls="$(count "$t/model-calls")"
review
jq -e '.posted == true and .decision == "hold"' "$(receipt)" > /dev/null
[[ "$(count "$t/model-calls")" == "$model_calls" ]]
tail -1 "$t/accepted" | jq -e '.verdict == "request_changes" and (.body_markdown | test("score 47 < floor 85"))' > /dev/null
rm "$t/gate-blocked"
# With the proof no longer in the way, the next head is reviewed and approved.
advance
review
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" ]]
jq -e '.posted == true and .decision == "approve"' "$(receipt)" > /dev/null
echo 'ok failing required proof held without a review, cleared proof approved'

# Pending proof admits the independent review, but no publication. A subsequent
# process reuses its exact-input result after proof succeeds, without another model call, although
# the row's live fields (updated_at, agents, checks) differ on every read.
advance
# The row also lists jankurai/proof among its required contexts, so signals.txt's live section moves
# from pending to success with the proof.
touch "$t/gate-pending" "$t/model-cost" "$t/with-contexts"
model_calls="$(count "$t/model-calls")"; posts_before="$(count "$t/posts")"
# Exercise production admission with its enabled default before proof's independent wait.
(unset REDTEAM_GATE_WAIT_SECS; review)
[[ "$(count "$t/model-calls")" == "$model_calls" && ! -e "$(receipt)" ]]
[[ "$(count "$t/posts")" == "$posts_before" ]]
wait_file="$t/state/pin-wait/jeryu/fixture/1-$(cat "$t/head").json"
jq --argjson first "$(( $(date +%s) - 5401 ))" '.first_seen_epoch=$first' "$wait_file" >"$t/wait-expired"
cat "$t/wait-expired" >"$wait_file"
(unset REDTEAM_GATE_WAIT_SECS; review)
rm "$t/model-cost"
jq -e '.posted == false and .decision == "waiting_gate"' "$(receipt)" >/dev/null
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" && "$(count "$t/posts")" == "$posts_before" ]]
grep -q 'waiting for jankurai/proof' "$t/controller.log"
pending="$t/state/pending/jeryu/fixture/1.json"
jq -e '.cost_usd == 0.4321' "$pending" >/dev/null
# While the proof still has no result, a computed head is left alone: no attempt, no agent.
attempts="$(find "$t/state/attempts" -type f | wc -l)"
review; review
jq -e '.posted == false and .decision == "waiting_gate"' "$(receipt)" >/dev/null
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" && "$(count "$t/posts")" == "$posts_before" ]]
[[ "$(find "$t/state/attempts" -type f | wc -l)" == "$attempts" ]]
rm "$t/gate-pending"
review
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" ]]
grep -q 'reusing review computed while proof was pending' "$t/controller.log"
# The published receipt names what the reused review cost; the saved result is used up.
jq -e '.posted == true and .decision == "approve" and .cost_usd == 0.4321' "$(receipt)" > /dev/null
[[ ! -e "$pending" ]]
# Its spend was reported once, by the attempt that ran the agent; the reuse reports none.
[[ "$(count "$t/events")" == 1 ]]
jq -e '.kind == "pr.reviewed" and .outcome == "waiting_gate" and .cost_usd == 0.4321' "$t/events" >/dev/null
rm "$t/events" "$t/with-contexts"
echo 'ok review runs during pending proof and is reused after green, across live row fields, without early publication'

# A finding about the pending result becomes stale when proof reports; recompute it instead
# of publishing the old block as a counted agent hold against the now-green context.
advance
touch "$t/gate-pending" "$t/with-contexts"
jq -n '{verdict:"block",summary:"Required proof has no result",findings:[{
  severity:"medium",title:"Required proof pending",file:"signals.txt",
  detail:"The required proof is still running.",evidence:"jankurai/proof: pending",
  pending_required_context:"jankurai/proof"}]}' >"$t/verdict"
model_calls="$(count "$t/model-calls")"
review
jq -e '.posted == false and .decision == "waiting_gate"' "$(receipt)" >/dev/null
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" ]]
rm "$t/gate-pending"
printf '{"verdict":"approve","summary":"fixture review complete","findings":[]}\n' >"$t/verdict"
review
[[ "$(count "$t/model-calls")" == "$((model_calls + 2))" ]]
jq -e '.posted == true and .decision == "approve"' "$(receipt)" >/dev/null
[[ ! -e "$pending" ]]
grep -Fq 'cached result contains required-context findings; recomputing before reuse' "$t/controller.log"
rm "$t/with-contexts"
echo 'ok pending-context findings receive a fresh review when proof reports'

# A proof that fails while the agent runs is the quality gate's mechanical hold, never a neutral
# wait, and the computed result is not kept.
advance
touch "$t/gate-pending" "$t/model-turns-red"
posts_before="$(count "$t/posts")"
review
rm -f "$t/model-turns-red"
jq -e '.decision == "hold" and .posted == true
  and (.verdict.findings[0].title == "jankurai/proof does not pass on this head")' "$(receipt)" >/dev/null
[[ "$(count "$t/posts")" == "$((posts_before + 1))" ]]
jq -e '.verdict == "request_changes"' <<<"$(tail -1 "$t/posts")" >/dev/null
jq -se 'last | .conclusion == "action_required"' "$t/check-runs" >/dev/null
[[ ! -e "$pending" ]]
rm -f "$t/gate-blocked"
echo 'ok a proof that turns red while the agent runs holds mechanically'

# A push while proof is pending invalidates the saved review.
advance
touch "$t/gate-pending"
review
model_calls="$(count "$t/model-calls")"
advance
review
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" ]]
jq -e '.posted == false and .decision == "waiting_gate"' "$(receipt)" >/dev/null
rm "$t/gate-pending"
review
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" ]]
jq -e '.posted == true and .decision == "approve"' "$(receipt)" >/dev/null

# Review-input changes and unsafe cached data cannot reuse a pending verdict.
advance
touch "$t/gate-pending"
review
model_calls="$(count "$t/model-calls")"
REDTEAM_MODEL=fixture-new-model review
[[ "$(count "$t/model-calls")" == "$((model_calls + 1))" ]]
review
[[ "$(count "$t/model-calls")" == "$((model_calls + 2))" ]]
jq --rawfile secret "$t/token" '.verdict.summary=$secret' "$pending" > "$t/unsafe-pending"
mv "$t/unsafe-pending" "$pending"
rm "$t/gate-pending"
review
[[ "$(count "$t/model-calls")" == "$((model_calls + 3))" ]]
jq -e '.posted == true and .decision == "approve"' "$(receipt)" >/dev/null
echo 'ok changed review identity and unsafe cached verdict both require a fresh review'

# A base branch the forge does not have yet is recorded once and not retried: no model call, no
# publication, and no second attempt for the same head however many passes run.
advance
g switch -q --detach HEAD
g branch -D main
model_calls="$(count "$t/model-calls")"; posts_before="$(count "$t/posts")"
review
jq -e '.decision == "base_missing" and .posted == false and .base_ref == "main"' "$(receipt)" > /dev/null
grep -q 'base branch main does not exist yet' "$t/controller.log"
attempts="$(find "$t/state/attempts" -type f | wc -l)"
review
[[ "$(find "$t/state/attempts" -type f | wc -l)" == "$attempts" ]]
[[ "$(count "$t/model-calls")" == "$model_calls" && "$(count "$t/posts")" == "$posts_before" ]]
grep -q 'skip — main does not exist yet' "$t/controller.log"
! grep -q 'fetch failed' "$t/controller.log"
g rev-parse HEAD > "$t/base"; g branch main "$(cat "$t/base")"; g switch -q topic
echo 'ok missing base branch recorded once, never retried'

# A review whose agent said what it cost puts one `pr.reviewed` event on the forge's log with the
# dollars and per-model token usage; a dry run and an agent that reports no cost post nothing.
[[ ! -e "$t/events" ]]
advance
touch "$t/model-cost"
checks_before_dry="$(count "$t/check-runs")"
"$here/pr-redteam" _review 1 0 0 jeryu/fixture 1 >> "$t/controller.log" 2>&1
[[ "$(count "$t/check-runs")" == "$checks_before_dry" ]]
# The error/completion trap has the same deny capability as a successful dry run.
advance
touch "$t/model-fail"
"$here/pr-redteam" _review 1 0 0 jeryu/fixture 1 >> "$t/controller.log" 2>&1
[[ "$(count "$t/check-runs")" == "$checks_before_dry" ]]
rm "$t/model-fail"
[[ ! -e "$t/events" ]]
review
[[ "$(count "$t/events")" == 1 ]]
jq -e --arg sha "$(cat "$t/head")" '.kind == "pr.reviewed" and .source == "pr-redteam" and .repo == "jeryu/fixture"
  and .pr == 1 and .sha == $sha and .outcome == "approve" and .cost_usd == 0.4321 and .seconds >= 0
  and (.event_id | length <= 64) and (.event_id | startswith("pr-redteam:\($sha[0:12]):reviewed:"))
  and .detail.decision == "approve" and .detail.automation == "pr-redteam"
  and .detail.usage == {"model-x": {input: 12, output: 3400, cache_read: 250000, cache_write: 9000,
                                    thinking: 800, cost_usd: 0.4321}}' "$t/events" > /dev/null
rm "$t/model-cost"
advance
review
[[ "$(count "$t/events")" == 1 ]]
echo 'ok review cost reported once per costed attempt, never on a dry run'

# Each finding of a review is a `review.finding` event from the agent reviewer; a later head that no
# longer shows one gets a `review.resolved` (caught) naming it.
printf '{"verdict":"approve","summary":"fixture review complete","findings":[{"severity":"low","title":"name is vague","file":"README.md","line":2,"detail":"d","evidence":"e"}]}\n' > "$t/verdict"
advance
review
before="$(count "$t/events")"
finding_sha="$(cat "$t/head")"
jq -s -e --arg sha "$finding_sha" '.[-1].events | length == 1 and .[0].kind == "review.finding"
  and .[0].source == "pr-redteam" and .[0].sha == $sha and .[0].pr == 1 and .[0].outcome == "low"
  and (.[0].event_id | length <= 64) and .[0].detail.reviewer_kind == "agent"
  and .[0].detail.path == "README.md" and .[0].detail.line == 2' "$t/events" > /dev/null
printf '{"verdict":"approve","summary":"fixture review complete","findings":[]}\n' > "$t/verdict"
advance
review
[[ "$(count "$t/events")" == "$((before + 1))" ]]
jq -s -e --arg old "${finding_sha:0:12}" '.[-1].events | length == 1 and .[0].kind == "review.resolved"
  and .[0].outcome == "caught" and .[0].detail.finding == "pr-redteam:\($old):finding:0"
  and (.[0].event_id | length <= 64)' "$t/events" > /dev/null
echo 'ok findings reported per head, and resolved once a later head drops them'

# A verdict the forge refused to publish reports no findings, and re-reviewing a head that is no
# longer the pull request's head reports nothing resolved.
printf '{"verdict":"approve","summary":"fixture review complete","findings":[{"severity":"low","title":"stale","file":"README.md","line":2,"detail":"d","evidence":"e"}]}\n' > "$t/verdict"
advance
touch "$t/reject"
before="$(count "$t/events")"
review
rm "$t/reject"
jq -e '.posted == false' "$(receipt)" > /dev/null
! tail -n +"$((before + 1))" "$t/events" | grep -q review.finding
echo 'ok no findings reported for a review the forge refused'

# A full pass over a head this tool did not approve lands nothing and rewrites no branch, even with
# a merger credential present. Landing an approved head is test/merge-pass.sh.
"$here/pr-redteam" run --repo jeryu/fixture --pr 1 >> "$t/controller.log" 2>&1
[[ ! -e "$t/danger" ]]
jq -es 'all(.[]; .decision != "reviewing")' "$t/state/attempts/jeryu/fixture/"*.json > /dev/null
[[ ! -e "$t/state/beats/current/jeryu_fixture-1.json" ]]
echo 'PUBLICATION AND RECOVERY PASS'
