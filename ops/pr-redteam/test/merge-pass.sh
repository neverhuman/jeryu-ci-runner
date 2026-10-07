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
    https://git.neverhuman.org/git/jeryu/fixture.git) args+=("$MERGE_FIXTURE/repo") ;;
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
      state:"open",passport_hash:"fixture-passport",review:{changes_requested:0},
      mergeable:{can_merge:$can,reason:$why}}'
}
case "$url" in
  */api/v3/user)
    if [[ "$bearer" == "$(cat "$MERGE_FIXTURE/merge-token")" ]]; then printf '{"login":"jain-merge-bot"}\n200'
    else printf '{"login":"independent-reviewer"}\n200'; fi ;;
  */api/v1/repos) printf '{"repositories":[{"id":{"owner":"jeryu","name":"fixture"},"family":"jain","open_pull_requests":1}]}\n200' ;;
  *'/pulls?state=open') row | jq -c '{items:[.]}'; printf '\n200' ;;
  # The detail route nests the row under .summary, beside the passport (live forge shape).
  */pulls/107) row | jq -c '{summary: ., merge_passport:{blockers:[]}, passport_hash, reviews: []}'; printf '\n200' ;;
  */pulls/107/checks) checks ;;
  */pulls/107/merge)
    if [[ -e "$MERGE_FIXTURE/required-failing" ]]; then printf '{"message":"required contexts are not green"}\n409'; exit 0; fi
    if [[ "$(jq -r .expected_head_sha <<< "$data")" != "$(cat "$MERGE_FIXTURE/head")" ]]; then printf '{"message":"head changed"}\n409'; exit 0; fi
    jq -c . <<< "$data" >> "$MERGE_FIXTURE/merges"; printf '{"merged":true}\n200' ;;
  */reviews)
    jq -c . <<< "$data" >> "$MERGE_FIXTURE/posts"; printf '{"ok":true}\n201' ;;
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
export JERYU_BASE=https://git.neverhuman.org
pass() { "$here/pr-redteam" run --repo jeryu/fixture --pr 107 >> "$t/controller.log" 2>&1; }
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
pass
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
echo 'MERGE PASS'
