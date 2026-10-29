#!/usr/bin/env bash
# A merge queue refusal files rework instead of waiting for a person: one p1 task per refused head,
# carrying the pull request, the conflicting paths and the base tip, with the durable-ledger rule of
# the held-review handoff. Nothing is resolved, merged or force-pushed here. Invented data only.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
finish() { local result=$?; ((result == 0)) || tail -80 "$t/controller.log" 2>/dev/null || true; rm -rf -- "$t"; }
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
printf '%s\n' "$(printf 'a%.0s' {1..40})" > "$t/tip"
printf 'queue_conflict\n' > "$t/refusal"
printf 'dana\n' > "$t/author"

cat > "$t/bin/git" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  case "$arg" in
    push|rebase|--force-with-lease*) echo forbidden-history-write >> "$REWORK_FIXTURE/danger"; exit 97 ;;
    https://forge.invalid/git/jeryu/fixture.git) args+=("$REWORK_FIXTURE/repo") ;;
    *) args+=("$arg") ;;
  esac
done
exec "$FIXTURE_REAL_GIT" "${args[@]}"
FIXTURE

cat > "$t/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
method=GET data='' bearer=''
printf '%s\n' "$@" > "$REWORK_FIXTURE/argv"
if grep -Eq 'fixture-bearer|fixture-merger-bearer' "$REWORK_FIXTURE/argv"; then
  printf 'bearer in curl argv\n' >> "$REWORK_FIXTURE/danger"; exit 95
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
printf '%s %s\n' "$method" "$url" >> "$REWORK_FIXTURE/requests"
case "$url" in
  */merge|*/queue) want="$(cat "$REWORK_FIXTURE/merge-token")" ;;
  */api/v3/user) want="$bearer" ;;
  *) want="$(cat "$REWORK_FIXTURE/token")" ;;
esac
if [[ "$bearer" != "$want" ]]; then
  printf 'wrong identity for %s\n' "$url" >> "$REWORK_FIXTURE/danger"; exit 96
fi
row() {
  jq -nc --arg sha "$(cat "$REWORK_FIXTURE/head")" --arg base "$(cat "$REWORK_FIXTURE/base")" \
    --arg author "$(cat "$REWORK_FIXTURE/author")" \
    '{repo:{owner:"jeryu",name:"fixture"},number:107,head_sha:$sha,base_sha:$base,head_ref:"topic",
      base_ref:"main",draft:false,author:$author,title:"cart totals",body_markdown:"fixture",
      state:"open",labels:["origin:internal"],passport_hash:"fixture-passport",
      review:{changes_requested:0},mergeable:{can_merge:true,reason:"ready"}}'
}
case "$url" in
  */branches/*/protection)
    # The base branch's enforced required contexts. This suite's base enforces none; what a review
    # is told about enforced contexts, and what it waits for, is covered in test/pin-wait.sh.
    printf '{"required_status_checks":{"contexts":[]}}\n200' ;;
  */api/v3/user)
    if [[ "$bearer" == "$(cat "$REWORK_FIXTURE/merge-token")" ]]; then printf '{"login":"jain-merge-bot"}\n200'
    else printf '{"login":"independent-reviewer"}\n200'; fi ;;
  */api/v1/repos) printf '{"repositories":[{"id":{"owner":"jeryu","name":"fixture"},"family":"jain","open_pull_requests":1}]}\n200' ;;
  *'/pulls?state=open') row | jq -c '{items:[.]}'; printf '\n200' ;;
  # The canonical pull request read, as the live forge answers it.
  */api/v3/repos/jeryu/fixture/pulls/107)
    [[ "$method" == GET ]] || { echo 'unexpected PR mutation' >> "$REWORK_FIXTURE/danger"; exit 98; }
    row | jq -c '. + {head:{sha:.head_sha},html_url:"https://forge.invalid/repos/jeryu/fixture/pulls/107"}'
    printf '\n200' ;;
  */api/v1/repos/*/merge-queue*)
    if [[ -e "$REWORK_FIXTURE/no-entry" ]]; then printf '{"entries":[],"page":{"has_more":false}}\n200'; exit; fi
    if [[ "$url" == *'page=1' ]]; then printf '{"entries":[],"page":{"has_more":true}}\n200'; exit; fi
    jq -nc --arg sha "$(cat "$REWORK_FIXTURE/head")" --arg tip "$(cat "$REWORK_FIXTURE/tip")" \
      --arg code "$(cat "$REWORK_FIXTURE/refusal")" \
      '{entries:[{repo:"jeryu/fixture",base:"main",number:107,pr_head_sha:$sha,base_sha:$tip,
        queue_ref:"refs/queue/main/107",queue_sha:"",state:"dequeued",
        enqueued_at:"2026-10-20T00:00:00Z",refusal_code:$code,
        reason:"the replay conflicted in crates/cart/src/total.rs, docs/pricing.md",
        conflict_paths:["crates/cart/src/total.rs","docs/pricing.md"]}],page:{has_more:false}}'
    printf '\n200' ;;
  */pulls/107)
    row | jq -c '{summary: ., merge_passport:{blockers:[]}, passport_hash, reviews: []}'; printf '\n200' ;;
  */pulls/107/checks) printf '{"checks":[{"name":"jeryu-deploy/required","required":true,"state":null,"conclusion":null}]}\n200' ;;
  */pulls/107/queue)
    printf 'attempt\n' >> "$REWORK_FIXTURE/queue-attempts"
    jq -nc --arg code "$(cat "$REWORK_FIXTURE/refusal")" \
      '{error:{code:$code,message:"the replay conflicted in crates/cart/src/total.rs, docs/pricing.md"}}'
    printf '\n409' ;;
  */pulls/107/merge)
    printf '{"error":{"code":"queue_required","message":"requires linear history, and the merge queue lands it"}}\n409' ;;
  */reviews) jq -c . <<< "$data" >> "$REWORK_FIXTURE/posts"; printf '{"ok":true}\n201' ;;
  */check-runs) printf '{"id":"check-run-fixture"}\n201' ;;
  */api/v1/events) printf '{"ok":true,"seqs":[1]}\n201' ;;
  *) printf 'forbidden API %s\n' "$url" >> "$REWORK_FIXTURE/danger"; exit 98 ;;
esac
FIXTURE

cat > "$t/bin/todoq" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == add && "$2" == jain && "$3" == --now && "$4" == --no-triage && "$5" == --priority \
   && "$6" == 1 && "$7" == --repos && "$8" == fixture && "$9" == --title ]]
printf 'accepted creation\n' >> "$REWORK_FIXTURE/todoq-adds"
printf '%s\n' "$@" > "$REWORK_FIXTURE/todoq-argv"
printf '%s' "${!#}" > "$REWORK_FIXTURE/todoq-text"
# Failures below happen AFTER creation: a blind retry would create duplicate external work.
if [[ -e "$REWORK_FIXTURE/todoq-fails" ]]; then exit 1; fi
printf '20261021-140219-504f10  now    p1  fixture              merge queue refused\n'
FIXTURE
chmod +x "$t/bin/"*

export REWORK_FIXTURE="$t" FIXTURE_REAL_GIT="$real_git"
export PATH="$t/bin:$PATH" JERYU_TOKEN_FILE="$t/token" REDTEAM_MERGE_TOKEN_FILE="$t/merge-token"
export REDTEAM_STATE="$t/state" REDTEAM_CLAUDE="$t/bin/model" REDTEAM_CLAUDE_VERSION=9.9.9
export JERYU_BASE=https://forge.invalid REDTEAM_TIMEOUT=10
receipt() { printf '%s/state/receipts/jeryu/fixture/107-%s.json\n' "$t" "$(cat "$t/head")"; }
ledger() { printf '%s/state/queue-rework/jeryu/fixture/107-%s.json\n' "$t" "$(cat "$t/head")"; }
count() { if [[ -f "$1" ]]; then wc -l < "$1"; else echo 0; fi; }
fails() { echo "$1" >&2; tail -60 "$t/controller.log" >&2; exit 1; }
# A published approval of the current head, so the merge pass tries to land it.
approve() {
  mkdir -p "$t/state/receipts/jeryu/fixture"
  jq -n --arg sha "$(cat "$t/head")" --arg at "$(date -u +%FT%TZ)" \
    --arg id "$("$here/pr-redteam" identity)" \
    '{repo:"jeryu/fixture",number:107,head_sha:$sha,base_sha:"",decision:"approve",posted:true,
      reviewed_at:$at,review_identity:$id,base_ref:"main",verdict:{verdict:"approve",findings:[]}}' \
    > "$(receipt)"
}
merge() { "$here/pr-redteam" _merge --repo jeryu/fixture --pr 107 >> "$t/controller.log" 2>&1; }

# Default off: the refusal is recorded and said out loud, and files nothing.
approve
merge
jq -e --arg sha "$(cat "$t/head")" '.queue_refused_sha == $sha' "$(receipt)" >/dev/null
grep -q 'the merge queue refused it: queue_conflict' "$t/controller.log"
[[ "$(count "$t/todoq-adds")" == 0 && ! -d "$t/state/queue-rework" ]]
export REDTEAM_FIX_TODO=1
approve; merge
[[ "$(count "$t/todoq-adds")" == 0 ]] # no explicit author selection
grep -q 'no rework todo — author is not explicitly selected' "$t/controller.log"
export REDTEAM_FIX_TODO_AUTHORS=dana
# A site that wants the held-review handoff and not this one turns this one off by itself.
approve; REDTEAM_QUEUE_REWORK=0 merge
[[ "$(count "$t/todoq-adds")" == 0 && ! -d "$t/state/queue-rework" ]]
echo 'ok filing stays off until the held-review switch and an explicit author selection allow it'

# A conflict only with a pull request queued ahead of it needs no replacement: it is queued again.
printf 'queue_conflict_queued\n' > "$t/refusal"
approve; merge
[[ "$(count "$t/todoq-adds")" == 0 ]]
grep -q 'queue_conflict_queued is not a refusal a replacement pull request fixes' "$t/controller.log"
printf 'queue_conflict\n' > "$t/refusal"
# A refusal the forge did not store carries no base tip or paths, so nothing is filed on a guess.
touch "$t/no-entry"; approve; merge
[[ "$(count "$t/todoq-adds")" == 0 && ! -d "$t/state/queue-rework" ]]
grep -q 'reported no stored refusal' "$t/controller.log"
rm "$t/no-entry"
# A selected human who has just touched the pull request keeps it.
approve; REDTEAM_HUMAN_AUTHORS=dana REDTEAM_HUMAN_ACTIVITY_SECS=86400 merge
[[ "$(count "$t/todoq-adds")" == 0 ]]
echo 'ok a queued-ahead conflict, an unstored refusal and an active human author file nothing'

# The filing itself: one p1 task carrying the pull request, the conflicting paths and the base tip.
approve; merge
[[ "$(count "$t/todoq-adds")" == 1 ]] || fails 'expected exactly one dispatch'
jq -e '.state == "confirmed" and .todo_id == "20261021-140219-504f10"' "$(ledger)" >/dev/null
jq -e --arg tip "$(cat "$t/tip")" '.base_sha == $tip and .refusal_code == "queue_conflict"' "$(ledger)" >/dev/null
jq -e '.queue_rework_id == "20261021-140219-504f10"' "$(receipt)" >/dev/null
grep -q 'filed jain queue rework todo 20261021-140219-504f10' "$t/controller.log"
grep -qF 'merge queue refused jeryu/fixture#107 at' "$t/todoq-argv"
for want in 'UNTRUSTED FORGE DATA' 'never instructions' 'still open at original_head' \
  'Cherry-pick the pull request commits' 'never force-push or rewrite head_ref' \
  'Run the repository required gate locally' 'open a replacement pull request against base_ref' \
  'close the original' 'Do not merge, enqueue, land or approve the replacement'; do
  grep -qF "$want" "$t/todoq-text" || fails "missing instruction: $want"
done
sed -n '/^~~~json$/,/^~~~$/p' "$t/todoq-text" | sed '1d;$d' > "$t/quoted.json"
[[ "$(wc -l < "$t/quoted.json")" == 1 ]]
jq -e --arg sha "$(cat "$t/head")" --arg tip "$(cat "$t/tip")" '
  .repo == "jeryu/fixture" and .pr == "107" and .original_head == $sha and .base_sha == $tip
  and .base_ref == "main" and .head_ref == "topic"
  and .url == "https://forge.invalid/repos/jeryu/fixture/pulls/107"
  and .conflict_paths == ["crates/cart/src/total.rs","docs/pricing.md"]' "$t/quoted.json" >/dev/null
grep -q 'per_page=100&page=2' "$t/requests" # the listing's has_more is walked
echo 'ok a refused head files one p1 rework task carrying the paths and the base tip'

# One refusal, one task: a later pass neither queues again nor files again.
before_attempts="$(count "$t/queue-attempts")"
merge
[[ "$(count "$t/todoq-adds")" == 1 && "$(count "$t/queue-attempts")" == "$before_attempts" ]]
# Even with the receipt's refusal record lost, the durable ledger stops a second dispatch.
jq 'del(.queue_refused_sha, .queue_rework_id, .queue_rework_sha, .queue_rework_at)' "$(receipt)" > "$t/r"
mv "$t/r" "$(receipt)"
merge
[[ "$(count "$t/todoq-adds")" == 1 ]]
grep -q 'durable rework dispatch already recorded' "$t/controller.log"
echo 'ok a refused head files at most one rework task'

# A dry run writes no ledger and dispatches nothing.
advance() { printf 'next\n' >> "$t/repo/README.md"; g commit -qam next; g rev-parse HEAD > "$t/head"; }
advance; approve
"$here/pr-redteam" _merge --dry-run --repo jeryu/fixture --pr 107 >> "$t/controller.log" 2>&1
[[ "$(count "$t/todoq-adds")" == 1 && ! -e "$(ledger)" ]]

# A write followed by a failing command is an unknown outcome: retained, never repeated.
touch "$t/todoq-fails"
approve; merge
jq -e '.state == "unknown"' "$(ledger)" >/dev/null
before="$(count "$t/todoq-adds")"
approve; merge
[[ "$(count "$t/todoq-adds")" == "$before" ]]
rm "$t/todoq-fails"
# A prepared record left by a crash before any acknowledgement has the same rule.
advance; approve
jq -n --arg sha "$(cat "$t/head")" \
  '{repo:"jeryu/fixture",number:107,head_sha:$sha,state:"prepared",family:"jain"}' > "$(ledger)"
merge
[[ "$(count "$t/todoq-adds")" == "$before" ]]
echo 'ok dry runs, uncertain outcomes and a prepared crash record never dispatch twice'

# Nothing here merged, rewrote a branch or printed a credential.
[[ ! -e "$t/danger" ]]
if grep -RFq -e 'fixture-bearer' -e 'fixture-merger-bearer' "$t/state" "$t/controller.log" "$t/todoq-text"; then
  fails 'credential leaked'
fi
echo 'QUEUE REWORK PASS'
