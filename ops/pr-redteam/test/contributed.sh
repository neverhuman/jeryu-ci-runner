#!/usr/bin/env bash
# Contributed pull requests, against stand-in forge/model processes: a contribution with a clean
# review is posted as advice and never approved, queued or merged, its review spend is capped per
# head, per pull request and per day, and an internal pull request behaves exactly as before.
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
printf 'contributed\n' > "$t/origin"
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
    push|rebase|--force-with-lease*) echo forbidden-history-write >> "$CONTRIB_FIXTURE/danger"; exit 97 ;;
    https://forge.invalid/git/acme/widget.git) args+=("$CONTRIB_FIXTURE/repo") ;;
    *) args+=("$arg") ;;
  esac
done
exec "$FIXTURE_REAL_GIT" "${args[@]}"
FIXTURE
cat > "$t/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
method=GET data='' bearer='' url=''
while (($#)); do
  case "$1" in
    --config) [[ "$2" != - ]] || bearer="$(sed -n 's/^header = "Authorization: Bearer \(.*\)"$/\1/p')"; shift ;;
    -X) method="$2"; shift ;;
    --data) data="$2"; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
printf '%s %s\n' "$method" "$url" >> "$CONTRIB_FIXTURE/requests"
origin="$(cat "$CONTRIB_FIXTURE/origin")"
row() {
  jq -nc --arg sha "$(cat "$CONTRIB_FIXTURE/head")" --arg base "$(cat "$CONTRIB_FIXTURE/base")" \
    --arg label "origin:$origin" \
    '{repo:{owner:"acme",name:"widget"},number:16,head_sha:$sha,base_sha:$base,head_ref:"topic",
      base_ref:"main",draft:false,author:"outsider",title:"add a widget",body_markdown:"please merge",
      state:"open",labels:[$label],passport_hash:"fixture-passport",review:{changes_requested:0},
      mergeable:{can_merge:true}}'
}
case "$url" in
  */api/v3/user)
    if [[ "$bearer" == "$(cat "$CONTRIB_FIXTURE/merge-token")" ]]; then printf '{"login":"merge-bot"}\n200'
    else printf '{"login":"pr-agent"}\n200'; fi ;;
  */api/v1/repos) printf '{"repositories":[{"id":{"owner":"acme","name":"widget"},"family":"jain","open_pull_requests":1}]}\n200' ;;
  *'/pulls?state=open') row | jq -c '{items:[.]}'; printf '\n200' ;;
  */pulls/16) row | jq -c '. + {merge_passport:{blockers:[]}}'; printf '\n200' ;;
  */pulls/16/checks) printf '{"checks":[{"name":"acme/required","required":true,"conclusion":"success"}]}\n200' ;;
  */pulls/16/merge)
    # Nothing contributed may ever be merged from the controller.
    if [[ "$origin" == contributed ]]; then
      printf 'merged a contributed pull request\n' >> "$CONTRIB_FIXTURE/danger"; exit 94
    fi
    jq -c . <<< "$data" >> "$CONTRIB_FIXTURE/merges"; printf '{"merged":true}\n200' ;;
  */pulls/16/queue)
    printf 'queued a contributed pull request\n' >> "$CONTRIB_FIXTURE/danger"; exit 93 ;;
  */reviews)
    jq -c . <<< "$data" >> "$CONTRIB_FIXTURE/posts"; printf '{"ok":true}\n201' ;;
  */heartbeat) printf '{"accepted":true}\n200' ;;
  # Review-cost and notification events (main since this suite was written) are accepted and kept.
  */api/v1/events) jq -c . <<< "$data" >> "$CONTRIB_FIXTURE/events"; printf '{"ok":true,"seqs":[1],"duplicates":0}\n201' ;;
  *) printf 'forbidden API %s\n' "$url" >> "$CONTRIB_FIXTURE/danger"; exit 98 ;;
esac
FIXTURE
cat > "$t/bin/model" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then echo '9.9.9 (Claude Code)'; exit 0; fi
CONTRIB_FIXTURE="$(dirname "$(dirname "$0")")"
printf '%s\n' "$@" >> "$CONTRIB_FIXTURE/model-argv"
printf 'called\n' >> "$CONTRIB_FIXTURE/model-calls"
# A clean review: nothing found, and the agent says approve. On a contribution that is advice.
printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":1.25,"structured_output":{"verdict":"approve","summary":"fixture review complete","findings":[]}}\n'
FIXTURE
chmod +x "$t/bin/"*
export CONTRIB_FIXTURE="$t" FIXTURE_REAL_GIT="$real_git"
export PATH="$t/bin:$PATH" JERYU_TOKEN_FILE="$t/token" REDTEAM_MERGE_TOKEN_FILE="$t/merge-token"
export REDTEAM_STATE="$t/state" REDTEAM_CLAUDE="$t/bin/model" REDTEAM_CLAUDE_VERSION=9.9.9 REDTEAM_TIMEOUT=10
export JERYU_BASE=https://forge.invalid
pass() { "$here/pr-redteam" run --repo acme/widget --pr 16 >> "$t/controller.log" 2>&1; }
receipt() { printf '%s/state/receipts/acme/widget/16-%s.json\n' "$t" "$(cat "$t/head")"; }
count() { if [[ -f "$1" ]]; then wc -l < "$1"; else echo 0; fi; }
advance() { printf 'next\n' >> "$t/repo/README.md"; g commit -qam next; g rev-parse HEAD > "$t/head"; }

# A contributed head with a clean review is reviewed once, posted as a comment, and left unmerged.
pass
[[ "$(count "$t/model-calls")" == 1 ]]
jq -e '.decision == "advice" and .posted == true and .origin == "contributed" and (.merged_at // null) == null' \
  "$(receipt)" > /dev/null
jq -e '.verdict == "comment"' <<< "$(tail -1 "$t/posts")" > /dev/null
jq -r .body_markdown <<< "$(tail -1 "$t/posts")" | grep -q 'advice on a contributed pull request'
jq -r .body_markdown <<< "$(tail -1 "$t/posts")" | grep -q 'maintainer on the configured list'
[[ "$(count "$t/merges")" == 0 && ! -e "$t/danger" ]]
grep -q 'contributed — not landed from here' "$t/controller.log"
# The contribution was reviewed on the small purse, not the family's own.
grep -A1 -Fx -- '--max-budget-usd' "$t/model-argv" | tail -1 | grep -qx 2
echo 'ok a clean contributed review is advice, and nothing merges it'

# Its one review per head is spent: a second pass costs nothing and still merges nothing.
pass
[[ "$(count "$t/model-calls")" == 1 && "$(count "$t/posts")" == 1 && "$(count "$t/merges")" == 0 ]]
grep -q 'has had its one agent review' "$t/controller.log"
# Not even --force buys a second one: the cap is the point.
"$here/pr-redteam" run --repo acme/widget --pr 16 --force >> "$t/controller.log" 2>&1
[[ "$(count "$t/model-calls")" == 1 && "$(count "$t/posts")" == 1 ]]
echo 'ok one agent review per contributed head, force included'

# A new head is a new review, until the per-pull-request budget runs out. The first review cost
# $1.25, so a $2 per-PR cap is reached after the second.
advance
REDTEAM_CONTRIBUTED_PR_USD=2 pass
[[ "$(count "$t/model-calls")" == 2 && "$(count "$t/posts")" == 2 ]]
advance
REDTEAM_CONTRIBUTED_PR_USD=2 pass
[[ "$(count "$t/model-calls")" == 2 && "$(count "$t/posts")" == 2 ]]
grep -q 'review budget; left for a maintainer' "$t/controller.log"
echo 'ok a contributed pull request stops being reviewed at its own budget'

# The day's budget holds a head the pull request itself could still afford.
REDTEAM_CONTRIBUTED_PR_USD=100 REDTEAM_CONTRIBUTED_DAILY_USD=2 pass
[[ "$(count "$t/model-calls")" == 2 ]]
grep -q "today's \$2 contributed review budget is spent" "$t/controller.log"
echo "ok the day's contributed review budget holds the rest for a maintainer"

# Nothing above approved, queued, merged or leaked a bearer.
[[ "$(count "$t/merges")" == 0 && ! -e "$t/danger" ]]
if grep -q '"verdict":"approve"' "$t/posts"; then echo 'approved a contribution' >&2; exit 1; fi
if grep -RFq -e 'fixture-bearer' -e 'fixture-merger-bearer' "$t/state" "$t/controller.log"; then
  echo 'forbidden credential evidence' >&2; exit 1
fi

# An internal pull request is unaffected: the same clean review approves it, on the family's own
# budget, and the merge pass lands it.
printf 'internal\n' > "$t/origin"
advance
pass
[[ "$(count "$t/model-calls")" == 3 ]]
jq -e '.decision == "approve" and .posted == true and .origin == "internal"' "$(receipt)" > /dev/null
jq -e '.verdict == "approve"' <<< "$(tail -1 "$t/posts")" > /dev/null
[[ "$(count "$t/merges")" == 1 ]]
jq -e --arg sha "$(cat "$t/head")" '.expected_head_sha == $sha' <<< "$(tail -1 "$t/merges")" > /dev/null
grep -A1 -Fx -- '--max-budget-usd' "$t/model-argv" | tail -1 | grep -qx 20
[[ ! -e "$t/danger" ]]
echo 'ok an internal pull request is reviewed, approved and merged as before'

# A row the forge does not mark at all is read as contributed: no origin is not a reason to land it.
printf 'unknown\n' > "$t/origin"
advance
pass
jq -e '.decision == "advice" and .origin == "contributed"' "$(receipt)" > /dev/null
[[ "$(count "$t/merges")" == 1 && ! -e "$t/danger" ]]
# A forge without the marking can say so, and then its pull requests are internal again.
advance
REDTEAM_UNMARKED_ORIGIN=internal pass
jq -e '.decision == "approve" and .origin == "internal"' "$(receipt)" > /dev/null
[[ "$(count "$t/merges")" == 2 ]]
echo 'ok an unmarked row is contributed unless the site says otherwise'
echo 'CONTRIBUTED'
