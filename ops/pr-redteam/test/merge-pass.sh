#!/usr/bin/env bash
# The landing half of the controller, against stand-in forge/model processes: an approved head whose
# required context fails on its first attempt and succeeds on a retry is merged on a later pass,
# without a second review, and no branch is ever rewritten.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
finish() { local result=$?; ((result == 0)) || tail -60 "$t/controller.log" 2>/dev/null || true; rm -rf -- "$t"; }
trap finish EXIT
real_git="$(command -v git)"
mkdir -p "$t/bin" "$t/state" "$t/repo"
printf 'fixture-bearer\n' > "$t/token"
printf 'fixture-merger-bearer\n' > "$t/merge-token"
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
    push|rebase|--force-with-lease*) echo forbidden-history-write >> "$MERGE_FIXTURE/danger"; exit 97 ;;
    https://forge.invalid/git/jeryu/fixture.git) args+=("$MERGE_FIXTURE/repo") ;;
    *) args+=("$arg") ;;
  esac
done
exec "$FIXTURE_REAL_GIT" "${args[@]}"
FIXTURE
cat > "$t/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
method=GET data='' bearer=''
printf '%s\n' "$@" > "$MERGE_FIXTURE/argv"
# Neither identity's secret may appear in curl's arguments.
if grep -Eq 'fixture-bearer|fixture-merger-bearer' "$MERGE_FIXTURE/argv"; then
  printf 'bearer in curl argv\n' >> "$MERGE_FIXTURE/danger"; exit 95
fi
while (($#)); do
  case "$1" in
    --config) [[ "$2" != - ]] || bearer="$(sed -n 's/^header = "Authorization: Bearer \(.*\)"$/\1/p')"; shift ;;
    -X) method="$2"; shift ;;
    --data) data="$2"; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
printf '%s %s %s\n' "$method" "$url" "$bearer" >> "$MERGE_FIXTURE/requests"
# The merge and queue routes are the merger's; everything else is the reviewer's. Each identity
# resolves its own login, so /api/v3/user is reachable with either.
case "$url" in
  */merge|*/queue) want="$(cat "$MERGE_FIXTURE/merge-token")" ;;
  */api/v3/user) want="$bearer" ;;
  *) want="$(cat "$MERGE_FIXTURE/token")" ;;
esac
if [[ "$bearer" != "$want" ]]; then printf 'wrong identity for %s: %s\n' "$url" "$bearer" >> "$MERGE_FIXTURE/danger"; exit 96; fi
# A required context that is failing, then green on the gate runner's second attempt.
checks() {
  if [[ -e "$MERGE_FIXTURE/required-failing" ]]; then
    printf '{"checks":[{"name":"jeryu-deploy/required","required":true,"conclusion":"failing"}]}\n200'
  # As the live forge answers once a status-backed required context is green: neither state nor
  # conclusion on the row, while the pull request summary says it can merge.
  else printf '{"checks":[{"name":"jeryu-deploy/required","required":true,"state":null,"conclusion":null}]}\n200'; fi
}
row() {
  jq -nc --arg sha "$(cat "$MERGE_FIXTURE/head")" --arg base "$(cat "$MERGE_FIXTURE/base")" \
    --argjson can "$(test -e "$MERGE_FIXTURE/required-failing" -o -e "$MERGE_FIXTURE/behind" && echo false || echo true)" \
    --arg why "$(test -e "$MERGE_FIXTURE/behind" && echo 'behind main' || echo 'required contexts are not green yet')" \
    '{repo:{owner:"jeryu",name:"fixture"},number:107,head_sha:$sha,base_sha:$base,head_ref:"topic",
      base_ref:"main",draft:false,author:"contributor",title:"fixture",body_markdown:"fixture",
      state:"open",labels:["origin:internal"],passport_hash:"fixture-passport",review:{changes_requested:0},
      mergeable:{can_merge:$can,reason:$why}}'
}
case "$url" in
  */refs) printf '[]\n200' ;; # No protected-main boundary in this fixture.
  */branches/*/protection)
    # The base branch's enforced required contexts. This suite's base enforces none; what a review
    # is told about enforced contexts, and what it waits for, is covered in test/pin-wait.sh.
    printf '{"required_status_checks":{"contexts":[]}}\n200' ;;
  */api/v3/user)
    if [[ "$bearer" == "$(cat "$MERGE_FIXTURE/merge-token")" ]]; then printf '{"login":"jain-merge-bot"}\n200'
    else printf '{"login":"independent-reviewer"}\n200'; fi ;;
  */api/v1/repos) printf '{"repositories":[{"id":{"owner":"jeryu","name":"fixture"},"family":"jain","open_pull_requests":1}]}\n200' ;;
  *'/pulls?state=open') row | jq -c '{items:[.]}'; printf '\n200' ;;
  # The detail route nests the row under .summary, beside the passport (live forge shape).
  */pulls/107)
    if [[ -e "$MERGE_FIXTURE/detail-unavailable" ]]; then printf '{"message":"temporary detail outage"}\n503'; exit; fi
    row | jq -c '{summary: ., merge_passport:{blockers:[]}, passport_hash, reviews: []}'; printf '\n200' ;;
  */pulls/107/checks) checks ;;
  # The merge queue: a queue request is recorded; the forge-wide list shows the entry as failed on
  # the base in queue-failed, when that file exists.
  */pulls/107/queue)
    printf 'attempt\n' >> "$MERGE_FIXTURE/queue-attempts"
    if [[ -e "$MERGE_FIXTURE/queue-unavailable" ]]; then printf '{"message":"temporary queue outage"}\n503'; exit; fi
    printf 'queued\n' >> "$MERGE_FIXTURE/queue-posts"
    jq -nc --arg sha "$(cat "$MERGE_FIXTURE/head")" \
      '{repo:"jeryu/fixture",base:"main",number:107,pr_head_sha:$sha,queue_ref:"refs/queue/main/107",queue_sha:$sha,state:"building"}'
    printf '\n200' ;;
  */api/v1/merge-queue\?state=all*)
    if [[ -e "$MERGE_FIXTURE/list-unavailable" ]]; then printf '{"message":"temporary list outage"}\n503'; exit; fi
    if [[ -e "$MERGE_FIXTURE/queue-bulk" && "$url" == *'page=1' ]]; then
      # ~3 MB of other-head rows for the same pull request: past ARG_MAX, so any argv use fails.
      jq -nc '{entries:[range(0;12000) | {repo:"jeryu/fixture",base:"main",number:107,
        pr_head_sha:("b" * 40),base_sha:("c" * 40),state:"failed",enqueued_at:"2026-10-20T00:00:00Z",
        reason:("x" * 200)}],page:{has_more:true}}'
      printf '\n200'; exit
    fi
    if [[ -e "$MERGE_FIXTURE/queue-paged" && "$url" == *'page=1' ]]; then
      printf '{"entries":[],"page":{"has_more":true}}\n200'; exit
    fi
    if [[ -e "$MERGE_FIXTURE/queue-failed" ]]; then
      jq -nc --arg sha "$(cat "$MERGE_FIXTURE/head")" --arg b "$(cat "$MERGE_FIXTURE/queue-failed")" \
        --arg st "$(cat "$MERGE_FIXTURE/queue-state" 2>/dev/null || echo failed)" \
        --arg old "$(cat "$MERGE_FIXTURE/queue-stale" 2>/dev/null || true)" '
        {entries:((if $old != "" then [{repo:"jeryu/fixture",base:"main",number:107,pr_head_sha:$sha,
          base_sha:$old,state:"failed",enqueued_at:"2026-10-01T00:00:00Z"}] else [] end) +
          [{repo:"jeryu/fixture",base:"main",number:107,pr_head_sha:$sha,base_sha:$b,state:$st,
          enqueued_at:"2026-10-13T00:00:00Z",reason:"the gate failed on the replay"}]),page:{has_more:false}}'
    else printf '{"entries":[],"page":{"has_more":false}}'; fi
    printf '\n200' ;;
  */pulls/107/merge)
    if [[ -e "$MERGE_FIXTURE/check-run-lock" ]] && flock -n "$REDTEAM_STATE/run.lock" true; then
      echo 'merge released the parent run lock' >> "$MERGE_FIXTURE/danger"; exit 99
    fi
    if [[ -e "$MERGE_FIXTURE/required-failing" ]]; then printf '{"message":"required contexts are not green"}\n409'; exit 0; fi
    if [[ -e "$MERGE_FIXTURE/linear" ]]; then printf '{"message":"linear history: the head is behind main"}\n409'; exit 0; fi
    if [[ "$(jq -r .expected_head_sha <<< "$data")" != "$(cat "$MERGE_FIXTURE/head")" ]]; then printf '{"message":"head changed"}\n409'; exit 0; fi
    jq -c . <<< "$data" >> "$MERGE_FIXTURE/merges"; printf '{"merged":true}\n200' ;;
  */reviews)
    jq -c . <<< "$data" >> "$MERGE_FIXTURE/posts"; printf '{"ok":true}\n201' ;;
  */check-runs)
    jq -c . <<< "$data" >> "$MERGE_FIXTURE/check-runs"; printf '{"id":"check-run-fixture"}\n201' ;;
  */heartbeat) printf '{"accepted":true}\n200' ;;
  *) printf 'forbidden API %s\n' "$url" >> "$MERGE_FIXTURE/danger"; exit 98 ;;
esac
FIXTURE
cat > "$t/bin/model" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then echo '9.9.9 (Claude Code)'; exit 0; fi
MERGE_FIXTURE="$(dirname "$(dirname "$0")")"
printf 'called\n' >> "$MERGE_FIXTURE/model-calls"
printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"verdict":"approve","summary":"fixture review complete","findings":[]}}\n'
FIXTURE
chmod +x "$t/bin/"*
export MERGE_FIXTURE="$t" FIXTURE_REAL_GIT="$real_git"
export PATH="$t/bin:$PATH" JERYU_TOKEN_FILE="$t/token" REDTEAM_MERGE_TOKEN_FILE="$t/merge-token"
export REDTEAM_STATE="$t/state" REDTEAM_CLAUDE="$t/bin/model" REDTEAM_CLAUDE_VERSION=9.9.9 REDTEAM_TIMEOUT=10
export JERYU_BASE=https://forge.invalid
pass() { "$here/pr-redteam" run "$@" --repo jeryu/fixture --pr 107 >> "$t/controller.log" 2>&1; }
receipt() { printf '%s/state/receipts/jeryu/fixture/107-%s.json\n' "$t" "$(cat "$t/head")"; }
count() { if [[ -f "$1" ]]; then wc -l < "$1"; else echo 0; fi; }

# Pass one: the required context is on its first, failing attempt. The head is reviewed and
# approved, and the merge waits with the forge's own reason.
touch "$t/required-failing"
pass
jq -e '.posted == true and .decision == "approve" and (.merged_at // null) == null' "$(receipt)" > /dev/null
[[ "$(count "$t/model-calls")" == 1 && "$(count "$t/merges")" == 0 ]]
grep -q 'approved, waiting to merge: required context jeryu-deploy/required is failing' "$t/controller.log"

# Pass two: still failing. The review is skipped as already reviewed, and the merge keeps waiting —
# the skip covers the review only.
pass
[[ "$(count "$t/model-calls")" == 1 && "$(count "$t/merges")" == 0 ]]
grep -q 'already reviewed at' "$t/controller.log"
[[ "$(grep -c 'approved, waiting to merge' "$t/controller.log")" == 2 ]]
echo 'ok approved head waits for its required context, without re-reviewing'

# The gate runner's second attempt goes green. The next pass merges the approved head at the exact
# sha and passport it reviewed, as the merger identity, and asks for no second review.
rm "$t/required-failing"
touch "$t/check-run-lock"
pass
rm "$t/check-run-lock"
[[ "$(count "$t/model-calls")" == 1 && "$(count "$t/merges")" == 1 ]]
jq -e --arg sha "$(cat "$t/head")" '.expected_head_sha == $sha and .passport_hash == "fixture-passport"' \
  <<< "$(tail -1 "$t/merges")" > /dev/null
jq -e '.merged_by == "jain-merge-bot" and (.merged_at | length) > 0' "$(receipt)" > /dev/null
grep -q 'MERGED .* as jain-merge-bot' "$t/controller.log"
[[ "$(count "$t/posts")" == 1 ]]
echo 'ok recovered required context merged on a later pass, with no second review'

# A merged head is not merged again, and nothing here rewrote a branch or leaked a bearer.
pass
[[ "$(count "$t/merges")" == 1 && "$(count "$t/model-calls")" == 1 ]]
[[ ! -e "$t/danger" ]]
if grep -RFq -e 'fixture-bearer' -e 'fixture-merger-bearer' "$t/state" "$t/controller.log"; then
  echo 'forbidden credential or activation evidence' >&2; exit 1
fi

# A head that was behind its base and became mergeable lands on the pass that sees it mergeable,
# on the same path and with no second review.
advance() { printf 'next\n' >> "$t/repo/README.md"; g commit -qam next; g rev-parse HEAD > "$t/head"; }
advance
touch "$t/behind"
pass
jq -e '.posted == true and (.merged_at // null) == null' "$(receipt)" > /dev/null
[[ "$(count "$t/model-calls")" == 2 && "$(count "$t/merges")" == 1 ]]
grep -q 'approved, waiting to merge: behind main' "$t/controller.log"
rm "$t/behind"
pass
[[ "$(count "$t/model-calls")" == 2 && "$(count "$t/merges")" == 2 ]]
jq -e '.merged_by == "jain-merge-bot"' "$(receipt)" > /dev/null
echo 'ok head that was behind merged once it became mergeable, with no second review'

# Without a configured merger credential the review pass still runs and nothing is landed.
merges_before="$(count "$t/merges")"
rm -f "$(receipt)"
REDTEAM_MERGE_TOKEN_FILE='' pass
grep -q 'merge pass skipped: set REDTEAM_MERGE_TOKEN_FILE' "$t/controller.log"
[[ "$(count "$t/merges")" == "$merges_before" && "$(count "$t/posts")" == 3 ]]
# The merger credential gets the same custody checks as the reviewer's: a weakened one lands
# nothing and is not printed.
chmod 644 "$t/merge-token"
merges_before="$(count "$t/merges")"
pass
grep -q 'merge pass skipped: the merger credential was rejected' "$t/controller.log"
[[ "$(count "$t/merges")" == "$merges_before" && ! -e "$t/danger" ]]
chmod 600 "$t/merge-token"
echo 'ok merger credential custody enforced'

# A forced rereview holds this lock before replacing a cached approval.
receipt_file="$(receipt)"
jq 'del(.merged_at, .merged_by)' "$receipt_file" > "$t/receipt"
mv "$t/receipt" "$receipt_file"
merges_before="$(count "$t/merges")"
exec 9>"$t/state/locks/jeryu_fixture-107.lock"; flock -n 9
"$here/pr-redteam" _merge --repo jeryu/fixture --pr 107 >> "$t/controller.log" 2>&1
[[ "$(count "$t/merges")" == "$merges_before" ]]
grep -q 'review in progress; merge deferred' "$t/controller.log"
jq '.decision="block" | .posted=true' "$receipt_file" > "$t/receipt"
mv "$t/receipt" "$receipt_file"
exec 9>&-
"$here/pr-redteam" _merge --repo jeryu/fixture --pr 107 >> "$t/controller.log" 2>&1
[[ "$(count "$t/merges")" == "$merges_before" && ! -e "$t/danger" ]]
echo 'ok merge retains run lock and rechecks approval under the review lock'
# A queued failure's retry is consumed only by an accepted dispatch, never by observation.
advance
touch "$t/linear"
pass
[[ "$(count "$t/queue-posts")" == 1 ]]
jq -e --arg sha "$(cat "$t/head")" '.queued_sha == $sha' "$(receipt)" >/dev/null
base_a=$(printf '1%.0s' {1..40}); base_b=$(printf '2%.0s' {1..40})
printf '%s\n' "$base_a" >"$t/queue-failed"
cp "$(receipt)" "$t/before-retry.json"
pass --dry-run
cmp "$(receipt)" "$t/before-retry.json"
[[ "$(count "$t/queue-posts")" == 1 ]]
touch "$t/detail-unavailable"
pass
cmp "$(receipt)" "$t/before-retry.json"
rm "$t/detail-unavailable"
touch "$t/queue-unavailable"
pass
cmp "$(receipt)" "$t/before-retry.json"
[[ "$(count "$t/queue-posts")" == 1 ]]
rm "$t/queue-unavailable"
echo 'ok dry run, detail failure and rejected dispatch leave retry state unchanged'

# Unknown/read-failed lists and live entries do not consume a retry, and are not silent.
touch "$t/list-unavailable"
pass
cmp "$(receipt)" "$t/before-retry.json"
grep -q 'merge queue snapshot answered 503' "$t/controller.log"
rm "$t/list-unavailable"
printf 'building\n' >"$t/queue-state"
pass
cmp "$(receipt)" "$t/before-retry.json"
printf 'unknown\n' >"$t/queue-state"
pass
cmp "$(receipt)" "$t/before-retry.json"
grep -q 'invalid merge queue state' "$t/controller.log"
rm "$t/queue-state"
printf '\n' >"$t/queue-failed"
pass
cmp "$(receipt)" "$t/before-retry.json"
grep -q 'no valid failed base' "$t/controller.log"
printf '%s\n' "$base_a" >"$t/queue-failed"

# The live page.has_more contract leads to page two, then one accepted retry is recorded.
touch "$t/queue-paged" "$t/queue-bulk"
pass
[[ "$(count "$t/queue-posts")" == 2 ]]
jq -e --arg b "$base_a" '.queue_retried_base == $b and .queue_retry_bases == [$b]' "$(receipt)" >/dev/null
grep -q 'state=all&per_page=100&page=2' "$t/requests"
! grep -q 'Argument list too long' "$t/controller.log"
echo 'ok multi-megabyte queue pages are accumulated without argv overflow, exact head still selected'
rm "$t/queue-paged" "$t/queue-bulk"
pass
[[ "$(count "$t/queue-posts")" == 2 ]]
grep -q "approved, waiting to merge: merge queue entry failed on base ${base_a:0:12} after a retry" "$t/controller.log"

# A newer failure wins over an older unordered row; a changed base grants one accepted retry.
printf '%s\n' "$base_a" >"$t/queue-stale"
merges_before="$(count "$t/merges")"
rm "$t/linear"; printf '%s\n' "$base_b" >"$t/queue-failed"
pass
[[ "$(count "$t/merges")" == "$((merges_before + 1))" && "$(count "$t/queue-posts")" == 2 ]]
jq -e --arg a "$base_a" --arg b "$base_b" '.merged_by == "jain-merge-bot" and .queue_retry_bases == [$a,$b]' "$(receipt)" >/dev/null
rm "$t/queue-stale"
echo 'ok failed merge-queue entry retried once per base, latest failure selected, then landed'

# A permanently broken reviewed head cannot re-queue forever as main advances.
advance
rm "$t/queue-failed"
touch "$t/linear"
pass
before_queues=$(count "$t/queue-posts")
for digit in 3 4 5; do
  printf '%s\n' "$(printf '%040d' "$digit")" >"$t/queue-failed"
  pass
done
[[ "$(count "$t/queue-posts")" == "$((before_queues + 3))" ]]
jq -e '.queue_retry_bases | length == 3' "$(receipt)" >/dev/null
printf '%s\n' "$(printf '6%.0s' {1..40})" >"$t/queue-failed"
pass
[[ "$(count "$t/queue-posts")" == "$((before_queues + 3))" ]]
grep -q 'merge queue retry limit 3 reached' "$t/controller.log"
[[ ! -e "$t/danger" ]]
echo 'ok three total accepted retries cap a broken head across advancing bases'
echo 'MERGE PASS'
