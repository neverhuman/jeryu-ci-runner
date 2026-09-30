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
mkdir -p "$t/bin" "$t/state" "$t/repo"
printf 'fixture-bearer\n' > "$t/token"
git init -q -b main "$t/repo"
g() { "$real_git" -C "$t/repo" -c user.name=fixture -c user.email=fixture@example.invalid "$@"; }
printf 'base\n' > "$t/repo/README.md"; g add .; g commit -qm base
g rev-parse HEAD > "$t/base"
g switch -qc topic
printf 'candidate\n' >> "$t/repo/README.md"; g commit -qam candidate
g rev-parse HEAD > "$t/head"
cat > "$t/bin/git" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  case "$arg" in
    push|rebase|--force-with-lease*) echo forbidden-history-write >> "$PUBLISH_FIXTURE/danger"; exit 97 ;;
    https://git.neverhuman.org/git/jeryu/fixture.git) args+=("$PUBLISH_FIXTURE/repo") ;;
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
    '{repo:{owner:"jeryu",name:"fixture"},number:1,head_sha:$sha,base_sha:$base,head_ref:"topic",base_ref:"main",draft:false,author:"contributor",title:"fixture",body_markdown:"fixture",state:"open",passport_hash:"fixture-passport",review:{user_review_state:$approved,changes_requested:0},mergeable:{can_merge:true}}'
}
case "$url" in
  */api/v3/user) printf '{"login":"independent-reviewer"}\n200' ;;
  */api/v1/repos) printf '{"repositories":[{"id":{"owner":"jeryu","name":"fixture"},"family":"jain","open_pull_requests":1}]}\n200' ;;
  *'/pulls?state=open') row | jq -c '{items:[.]}'; printf '\n200' ;;
  */pulls/1)
    # The pull request detail: its merge passport says whether the base branch
    # requires jankurai/proof on this head and whether it passes.
    if [[ -e "$PUBLISH_FIXTURE/gate-blocked" ]]; then
      printf '{"merge_passport":{"blockers":[{"code":"passport_blocked_checks","message":"Required context `jankurai/proof` is failing."}]}}\n200'
    else printf '{"merge_passport":{"blockers":[]}}\n200'; fi ;;
  */pulls/1/checks)
    if [[ -e "$PUBLISH_FIXTURE/gate-blocked" ]]; then
      printf '{"checks":[{"name":"jankurai/proof","required":true,"title":"score 47 < floor 85"}]}\n200'
    else printf '{"checks":[]}\n200'; fi ;;
  */reviews)
    jq -c . <<< "$data" >> "$PUBLISH_FIXTURE/posts"
    if [[ -e "$PUBLISH_FIXTURE/reject" ]]; then printf '{"message":"publication refused"}\n403'
    elif [[ "$(jq -r .expected_head_sha <<< "$data")" != "$(cat "$PUBLISH_FIXTURE/head")" ]]; then printf '{"message":"head changed"}\n409'
    else jq -c . <<< "$data" >> "$PUBLISH_FIXTURE/accepted"; printf '{"ok":true}\n201'; fi ;;
  */heartbeat) printf '{"accepted":true}\n200' ;;
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
while [[ -e "$PUBLISH_FIXTURE/gate" ]]; do sleep 0.05; done
if [[ -e "$PUBLISH_FIXTURE/model-fail" ]]; then exit 42; fi
if [[ -e "$PUBLISH_FIXTURE/model-leak" ]]; then
  jq -nc --arg secret "$(cat "$PUBLISH_FIXTURE/token")" \
    '{type:"result",subtype:"success",is_error:false,structured_output:{verdict:"approve",summary:$secret,findings:[]}}'
else
  printf '{"type":"result","subtype":"success","is_error":false,"structured_output":%s}\n' "$(cat "$PUBLISH_FIXTURE/verdict")"
fi
FIXTURE
chmod +x "$t/bin/"*
printf '{"verdict":"approve","summary":"fixture review complete","findings":[]}\n' > "$t/verdict"
export PUBLISH_FIXTURE="$t" FIXTURE_REAL_GIT="$real_git"
export PATH="$t/bin:$PATH" JERYU_TOKEN_FILE="$t/token" REDTEAM_MERGE_TOKEN_FILE="$t/token"
export REDTEAM_STATE="$t/state" REDTEAM_CLAUDE="$t/bin/model" REDTEAM_CLAUDE_VERSION=9.9.9 REDTEAM_TIMEOUT=10
export JERYU_BASE=https://git.neverhuman.org
review() { "$here/pr-redteam" _review 0 0 0 jeryu/fixture 1 >> "$t/controller.log" 2>&1; }
receipt() { printf '%s/state/receipts/jeryu/fixture/1-%s.json\n' "$t" "$(cat "$t/head")"; }
count() { if [[ -f "$1" ]]; then wc -l < "$1"; else echo 0; fi; }
advance() { printf 'next\n' >> "$t/repo/README.md"; g commit -qam next; g rev-parse HEAD > "$t/head"; }
wait_model() { for ((i=0;i<200;i++)); do [[ ! -e "$t/model-started" ]] || return 0; sleep 0.05; done; echo 'model did not start' >&2; return 1; }

# Rejected publication is durable and retryable; a restart can publish once.
touch "$t/reject"
review
jq -e '.posted == false and .decision == "publication_rejected" and .post_http == "403"' "$(receipt)" > /dev/null
[[ "$(count "$t/accepted")" == 0 ]]
rm "$t/reject"
review
jq -e '.posted == true and .decision == "approve"' "$(receipt)" > /dev/null
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

# The normal review command has no merge pass or branch rewrite, even with a merger token present.
"$here/pr-redteam" run --repo jeryu/fixture --pr 1 >> "$t/controller.log" 2>&1
[[ ! -e "$t/danger" ]]
jq -es 'all(.[]; .decision != "reviewing")' "$t/state/attempts/jeryu/fixture/"*.json > /dev/null
[[ ! -e "$t/state/beats/current/jeryu_fixture-1.json" ]]
echo 'PUBLICATION AND RECOVERY PASS'
