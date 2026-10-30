#!/usr/bin/env bash
# Two holds, then a person: after REDTEAM_HOLD_CAP agent holds on one PR its next heads get only
# the mechanical checks, a head none of them holds is left
# for a person (said once per head on the PR's timeline), and no pass or poke spends a review on it
# until `pr-redteam rearm` or an operator's --force. Quality-gate, unpinned-blob and private-key
# holds do not count. The review footer says which hold this is. Invented data only.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
finish() { local result=$?; ((result == 0)) || tail -80 "$t/log" 2>/dev/null || true; rm -rf -- "$t"; }
trap finish EXIT
real_git="$(command -v git)"
mkdir -p "$t/bin" "$t/state" "$t/repo"
printf 'fixture-bearer\n' > "$t/token"
git init -q -b main "$t/repo"
g() { "$real_git" -C "$t/repo" -c user.name=fixture -c user.email=fixture@example.invalid "$@"; }
printf 'base\n' > "$t/repo/README.md"; g add .; g commit -qm base
g rev-parse HEAD > "$t/base"
g switch -qc cart-totals
printf 'let total = body.total;\n' > "$t/repo/cart.rs"; g add .; g commit -qm 'cart totals'
g rev-parse HEAD > "$t/head"

cat > "$t/bin/git" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  case "$arg" in
    push|--force-with-lease*) echo forbidden-history-write >> "$CAP_FIXTURE/danger"; exit 97 ;;
    https://forge.invalid/git/acme/widget-shop.git) args+=("$CAP_FIXTURE/repo") ;;
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
printf '%s %s\n' "$method" "$url" >> "$CAP_FIXTURE/requests"
# The forge's effective verdict is the reviewer's newest review on the exact head (jeryu-core
# reduce_reviews): a later approval by the same reviewer replaces its own request for changes, and
# no one else's review or dismissal does. Only this reviewer posts here, so its newest post decides.
changes_requested() {
  [[ -s "$CAP_FIXTURE/posts" ]] || { echo 0; return; }
  jq -s --arg sha "$(cat "$CAP_FIXTURE/head")" \
    'map(select(.expected_head_sha == $sha)) | if length > 0 and last.verdict == "request_changes" then 1 else 0 end' \
    "$CAP_FIXTURE/posts"
}
row() {
  local cr; cr="$(changes_requested)"
  jq -nc --arg sha "$(cat "$CAP_FIXTURE/head")" --arg base "$(cat "$CAP_FIXTURE/base")" \
    --argjson cr "$cr" --argjson red "$([[ -e "$CAP_FIXTURE/gate-failing" ]] && echo true || echo false)" \
    '{repo:{owner:"acme",name:"widget-shop"},number:7,head_sha:$sha,base_sha:$base,
      head_ref:"cart-totals",base_ref:"main",draft:false,author:"dana",title:"cart totals",
      state:"open",labels:["origin:internal"],passport_hash:"fixture-passport",
      review:{changes_requested:$cr},
      mergeable:(if $cr > 0 then {can_merge:false,reason:"changes requested"}
                 elif $red then {can_merge:false,reason:"required context failing"}
                 else {can_merge:true} end)}'
}
case "$url" in
  */refs) printf '[]\n200' ;; # No protected-main boundary in this fixture.
  */branches/*/protection)
    # The base branch's enforced required contexts. This suite's base enforces none; what a review
    # is told about enforced contexts, and what it waits for, is covered in test/pin-wait.sh.
    printf '{"required_status_checks":{"contexts":[]}}\n200' ;;
  */api/v3/user) printf '{"login":"independent-reviewer"}\n200' ;;
  */api/v1/repos) printf '{"repositories":[{"id":{"owner":"acme","name":"widget-shop"},"family":"widgets","open_pull_requests":1}]}\n200' ;;
  *'/pulls?state=open') row | jq -c '{items:[.]}'; printf '\n200' ;;
  */api/v3/repos/acme/widget-shop/pulls/7)
    row | jq -c '. + {head:{sha:.head_sha},html_url:"https://forge.invalid/repos/widgets/acme/widget-shop/pulls/7"}'; printf '\n200' ;;
  */pulls/7)
    # The quality gate fails while gate-failing exists; otherwise the head waits only for review.
    # gate-pending: the proof is queued; it fails once its checks were read (gate-fails-next).
    blockers='[{"code":"passport_blocked_approvals","message":"An approval is required."}]'
    [[ ! -e "$CAP_FIXTURE/gate-pending" ]] \
      || blockers='[{"code":"passport_blocked_checks","message":"Required context `jankurai/proof` is queued or running."}]'
    [[ ! -e "$CAP_FIXTURE/gate-failing" ]] \
      || blockers='[{"code":"passport_blocked_checks","message":"Required context `jankurai/proof` is failing."}]'
    row | jq -c --argjson b "$blockers" '{summary: ., merge_passport:{head_sha:.head_sha, blockers:$b}, passport_hash}'
    printf '\n200' ;;
  */pulls/7/checks)
    # The proof gets its failing result right after this read: later reads of the gate see it.
    if [[ -e "$CAP_FIXTURE/gate-fails-next" ]]; then
      rm -f "$CAP_FIXTURE/gate-fails-next" "$CAP_FIXTURE/gate-pending"; touch "$CAP_FIXTURE/gate-failing"
    fi
    printf '{"checks":[]}\n200' ;;
  */pulls/7/merge) jq -c . <<< "$data" >> "$CAP_FIXTURE/merged"; printf '{"merged":true}\n200' ;;
  */pulls/7/reviews)
    # The forge refuses reviews while reviews-failing exists.
    [[ ! -e "$CAP_FIXTURE/reviews-failing" ]] || { printf '{"error":"unavailable"}\n503'; exit 0; }
    jq -c . <<< "$data" >> "$CAP_FIXTURE/posts"; printf '{"ok":true}\n201' ;;
  */api/v1/events) printf '%s\n' "$data" >> "$CAP_FIXTURE/events"; printf '{"ok":true,"seqs":[1]}\n201' ;;
  */check-runs) printf '{"id":1}\n201' ;;
  *) printf 'forbidden API %s\n' "$url" >> "$CAP_FIXTURE/danger"; exit 98 ;;
esac
FIXTURE

cat > "$t/bin/model" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then echo '9.9.9 (Claude Code)'; exit 0; fi
CAP_FIXTURE="$(dirname "$(dirname "$0")")"
printf 'called\n' >> "$CAP_FIXTURE/model-calls"
jq -c '{type:"result",subtype:"success",is_error:false,structured_output:.}' "$CAP_FIXTURE/verdict"
FIXTURE

cat > "$t/bin/systemctl" <<'FIXTURE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CAP_FIXTURE/systemctl"
case "$*" in
  *is-active*) exit 3 ;;
  '--user start --no-block pr-redteam.service') exit 0 ;;
  *) echo "unexpected systemctl $*" >> "$CAP_FIXTURE/danger"; exit 97 ;;
esac
FIXTURE
cat > "$t/bin/todoq" <<'FIXTURE'
#!/usr/bin/env bash
[[ "$1" == add ]] || exit 0
printf 'called\n' >> "$CAP_FIXTURE/todos"
printf '%s\n' "${!#}" > "$CAP_FIXTURE/todo-text"
printf '20261020-172419-abcdef\n'
FIXTURE
chmod +x "$t/bin/"*

export CAP_FIXTURE="$t" FIXTURE_REAL_GIT="$real_git"
export PATH="$t/bin:$PATH" JERYU_TOKEN_FILE="$t/token" JERYU_BASE=https://forge.invalid
export REDTEAM_STATE="$t/state" REDTEAM_CLAUDE="$t/bin/model" REDTEAM_CLAUDE_VERSION=9.9.9
export REDTEAM_TIMEOUT=60 REDTEAM_MAX_BLOB_BYTES=100
pass() { "$here/pr-redteam" run --repo acme/widget-shop --pr 7 "$@" >> "$t/log" 2>&1; }
receipt() { printf '%s/state/receipts/acme/widget-shop/7-%s.json\n' "$t" "$(cat "$t/head")"; }
count() { if [[ -f "$1" ]]; then wc -l < "$1"; else echo 0; fi; }
fails() { echo "$1" >&2; tail -40 "$t/log" >&2; exit 1; }
changes_requested_now() {
  jq -s --arg sha "$(cat "$t/head")" \
    'map(select(.expected_head_sha == $sha)) | if length > 0 and last.verdict == "request_changes" then 1 else 0 end' "$t/posts"
}
footer() { jq -r .body_markdown <<<"$(tail -1 "$t/posts")" | tail -1; }
advance() { # a new head; an optional file name adds a binary/archive the diff does not pin
  if [[ -n "${1:-}" ]]; then head -c 300 /dev/urandom > "$t/repo/$1"; g add "$1"; g commit -qm 'add payload'
  else printf 'next head\n' >> "$t/repo/README.md"; g commit -qam 'author pushes'; fi
  g rev-parse HEAD > "$t/head"
}
critical='{severity:"critical",title:"Client total is trusted",file:"cart.rs",line:1,
  detail:"The server charges whatever total the client sends.",evidence:"+ let total = body.total;"}'
block() { jq -n "{verdict:\"block\",summary:\"charges the client total\",findings:[$critical]}" > "$t/verdict"; }
approve() { jq -n '{verdict:"approve",summary:"fine",findings:[]}' > "$t/verdict"; }

# A quality-gate hold is mechanical: no agent, and it does not count.
touch "$t/gate-failing"; approve
pass
jq -e '.decision == "hold" and .hold_kind == "gate" and .posted == true' "$(receipt)" >/dev/null || fails 'gate hold'
footer | grep -qF 'mechanical hold, not counted toward the hold limit' || fails "gate footer: $(footer)"
rm "$t/gate-failing"
# So is an unpinned blob, held whatever the agent concluded.
advance payload.bin; approve
pass
jq -e '.decision == "hold" and .hold_kind == "blob"' "$(receipt)" >/dev/null || fails 'blob hold'
footer | grep -qF 'mechanical hold, not counted' || fails "blob footer: $(footer)"
g rm -q payload.bin; g commit -qm 'drop payload'
echo 'ok quality-gate and blob holds are mechanical and say they do not count'

# The first agent hold.
advance; block
pass
jq -e '.decision == "hold" and .hold_kind == "agent" and .posted == true' "$(receipt)" >/dev/null || fails 'critical did not hold'
jq -e '.verdict == "request_changes"' <<<"$(tail -1 "$t/posts")" >/dev/null
footer | grep -qF 'hold 1 of 2: a new push is re-reviewed; after 2 holds this PR is left for a person' \
  || fails "first hold footer: $(footer)"
# The second, on a later head, is the last.
advance
pass
# shellcheck disable=SC2016 # the backticks are the literal review text
footer | grep -qF 'hold 2 of 2: this PR is now left for a person; later pushes are not reviewed automatically until a maintainer runs `pr-redteam rearm`' \
  || fails "second hold footer: $(footer)"
pass
[[ "$(count "$t/model-calls")" == 3 ]] || fails 'the held head was reviewed again'
echo 'ok an agent hold counts, and the footer counts holds against the cap'

# The third head gets no agent review. Poke may start one pass for it (its mechanical checks are
# due); none holds it, so it gets a blocking review naming the cap (never an approval), a final
# `capped` receipt and one pr.skipped event, and neither later passes nor pokes come back to it.
advance
calls="$(count "$t/model-calls")"; posts="$(count "$t/posts")"
starts() { grep -c 'start --no-block pr-redteam.service' "$t/systemctl" 2>/dev/null || true; }
"$here/pr-redteam" poke >> "$t/log" 2>&1
[[ "$(starts)" == 1 ]] || fails 'poke did not start the mechanical checks of a new capped head'
pass
[[ "$(count "$t/model-calls")" == "$calls" ]] || fails 'the agent reviewed a capped head'
[[ "$(count "$t/posts")" == "$((posts + 1))" ]] || fails 'a capped head did not get exactly one blocking review'
jq -e --arg sha "$(cat "$t/head")" '.verdict == "request_changes" and .expected_head_sha == $sha
    and (.body_markdown | contains("reached the hold cap") and contains("pr-redteam rearm acme/widget-shop 7")
         and contains("An approval alone does not clear this hold"))' <<<"$(tail -1 "$t/posts")" >/dev/null \
  || fails "capped review: $(tail -1 "$t/posts")"
jq -e '.decision == "capped" and .posted == true and .holds == 2' "$(receipt)" >/dev/null || fails 'no capped receipt'
grep -qF 'held 2 times; a person decides (pr-redteam rearm acme/widget-shop 7)' "$t/log" || fails 'cap reason not logged'
jq -s -e --arg sha "$(cat "$t/head")" 'map(select(.kind == "pr.skipped")) | length == 1 and (.[0] |
    .event_id == "pr-redteam:\($sha):hold-cap" and (.event_id | length) <= 64 and .sha == $sha
    and .pr == 7 and .repo == "acme/widget-shop" and .outcome == "skipped"
    and .detail == {automation: "pr-redteam", skipped: "hold_cap", holds: 2})' "$t/events" >/dev/null \
  || fails "pr.skipped event: $(cat "$t/events")"
pass
grep -qF 'skip acme/widget-shop#7 — held 2 times; a person decides' "$t/log" || fails 'capped receipt not final'
[[ "$(count "$t/model-calls")" == "$calls" && "$(count "$t/posts")" == "$((posts + 1))" \
   && "$(jq -s 'map(select(.kind == "pr.skipped")) | length' "$t/events")" == 1 ]] \
  || fails 'a second pass on a capped head did more work'
"$here/pr-redteam" poke >> "$t/log" 2>&1; "$here/pr-redteam" poke >> "$t/log" 2>&1
[[ "$(starts)" == 1 ]] || fails 'poke loops on a capped head'
# A review-identity change (here a review limit) re-admits the capped head, but its blocking review
# still stands: no second review, no second event, no agent; the receipt takes the new identity.
old_identity="$(jq -r .review_identity "$(receipt)")"
REDTEAM_MAX_BLOB_BYTES=101 pass
[[ "$(count "$t/model-calls")" == "$calls" && "$(count "$t/posts")" == "$((posts + 1))" \
   && "$(jq -s 'map(select(.kind == "pr.skipped")) | length' "$t/events")" == 1 ]] \
  || fails 'an identity change posted a second capped review'
jq -e --arg old "$old_identity" '.decision == "capped" and .posted == true and .post_http == "reused"
    and .review_identity != $old' "$(receipt)" >/dev/null || fails "identity-change capped receipt: $(cat "$(receipt)")"
grep -qF 'its blocking review is already posted' "$t/log" || fails 'reuse of the capped review not logged'
# A capped head is never landed: there is no approval to merge.
REDTEAM_MERGE_TOKEN_FILE="$t/token" "$here/pr-redteam" _merge > "$t/merge.log" 2>&1
cat "$t/merge.log" >> "$t/log"
! grep -q 'merge pass skipped' "$t/merge.log" || fails 'the merge pass did not run'
! grep -q '/merge\|/queue' "$t/requests" || fails 'the merge pass touched a capped head'
echo 'ok a clean capped head gets no agent review, one blocking review (kept across a review-identity change), a final capped receipt, one timeline event, and no merge'

# A capped head emits its process finding without resolving unreviewed code findings,
# and the opted-in handoff asks for a person rather than another repair push.
jq -s -e --arg sha "$(cat "$t/head")" '[.[] | .events[]? | select(.sha == $sha)] |
  any(.kind == "review.finding" and .detail.title == "Hold cap requires a person") and
  all(.kind != "review.resolved")' "$t/events" >/dev/null || fails 'cap finding ledger'
REDTEAM_FIX_TODO=1 REDTEAM_FIX_TODO_AUTHORS=dana pass
[[ "$(count "$t/todos")" == 1 ]] || fails 'cap did not dispatch one handoff'
jq -e '.state == "confirmed" and .todo_id == "20261020-172419-abcdef"' \
  "$t/state/fix-todos/acme/widget-shop/7-$(cat "$t/head").json" >/dev/null || fails 'cap dispatch not confirmed'
grep -qF 'Do not edit or push, automatically rearm' "$t/todo-text" || fails 'cap todo permits automation'
REDTEAM_FIX_TODO=1 REDTEAM_FIX_TODO_AUTHORS=dana pass
[[ "$(count "$t/todos")" == 1 ]] || fails 'cap handoff repeated'

# Gate and blob checks still produce mechanical holds once the agent budget is exhausted.
for kind in gate blob; do
  if [[ "$kind" == gate ]]; then advance; touch "$t/gate-failing"
  else advance payload.bin; fi
  pass
  jq -e --arg kind "$kind" '.decision == "hold" and .hold_kind == $kind and .posted == true' \
    "$(receipt)" >/dev/null || fails "capped $kind hold"
  [[ "$(count "$t/model-calls")" == "$calls" ]] || fails "agent ran for capped $kind"
  footer | grep -qF 'mechanical hold at the hold limit' || fails "capped $kind footer"
  if [[ "$kind" == gate ]]; then rm "$t/gate-failing"
  else g rm -q payload.bin; g commit -qm 'drop payload'; fi
done
echo 'ok capped findings, human handoff and gate/blob mechanical holds'

# A capped head whose blocking review could not be posted is not final: the next pass posts it.
advance
calls="$(count "$t/model-calls")"; posts="$(count "$t/posts")"
touch "$t/reviews-failing"
pass
rm -f "$t/reviews-failing"
jq -e '.decision == "capped" and .posted == false and .post_http == "503"' "$(receipt)" >/dev/null \
  || fails "failed capped post receipt: $(cat "$(receipt)")"
[[ "$(count "$t/posts")" == "$posts" ]] || fails 'a refused capped review was recorded as posted'
jq -s -e --arg sha "$(cat "$t/head")" '[.[] | .events[]? | select(.sha == $sha and .kind == "review.finding")] |
  length == 0' "$t/events" >/dev/null || fails 'unpublished cap emitted a finding'
pass
[[ "$(count "$t/model-calls")" == "$calls" ]] || fails 'the retry asked the agent'
[[ "$(count "$t/posts")" == "$((posts + 1))" ]] || fails 'the capped review was not retried'
jq -e '.decision == "capped" and .posted == true' "$(receipt)" >/dev/null || fails 'retried capped receipt not final'
jq -e '.verdict == "request_changes"' <<<"$(tail -1 "$t/posts")" >/dev/null || fails 'retry posted a non-blocking review'
echo 'ok a capped head whose blocking review was refused is retried on the next pass, without the agent'

# At the cap a committed private key still holds, mechanically, with no agent.
# The header is assembled at run time so this source carries no key-shaped line.
key_header="-----BEGIN OPENSSH ""PRIVATE KEY-----"
printf -- '%s\nfixture\n' "$key_header" > "$t/repo/id_fixture"
g add id_fixture; g commit -qm 'add key'; g rev-parse HEAD > "$t/head"
pass
[[ "$(count "$t/model-calls")" == "$calls" ]] || fails 'the agent ran at the cap'
jq -e '.decision == "hold" and .hold_kind == "secret" and .posted == true' "$(receipt)" >/dev/null || fails 'key not held at the cap'
jq -r .body_markdown <<<"$(tail -1 "$t/posts")" | grep -qF 'Committed private key' || fails 'key hold does not name the key'
footer | grep -qF 'mechanical hold at the hold limit: a push that clears it gets the mechanical checks only' \
  || fails "capped mechanical footer: $(footer)"
g rm -q id_fixture; g commit -qm 'drop key'
echo 'ok a capped head with a committed private key is held mechanically'

# An operator's --force reviews a capped head with the agent.
advance; approve
pass
jq -e '.decision == "capped"' "$(receipt)" >/dev/null || fails 'expected a capped head'
pass --force
[[ "$(count "$t/model-calls")" == "$((calls + 1))" ]] || fails '--force did not review a capped head'
jq -e '.decision == "approve" and .posted == true' "$(receipt)" >/dev/null
echo 'ok --force reviews a capped head'

# A maintainer rearms it: the capped head is reviewed again, and the count starts again from here.
advance; block
pass
jq -e '.decision == "capped"' "$(receipt)" >/dev/null || fails 'expected a capped head before rearm'
"$here/pr-redteam" rearm acme/widget-shop 7 >> "$t/log" 2>&1
jq -e '.holds == 2 and .repo == "acme/widget-shop" and .number == 7' "$t/state/rearm/acme_widget-shop-7" >/dev/null
[[ -z "$(find "$t/state/rearm" -name '*.??????')" ]] || fails 'rearm left a temporary file'
"$here/pr-redteam" poke >> "$t/log" 2>&1
[[ "$(starts)" == 2 ]] || fails 'poke ignored the rearm'
calls="$(count "$t/model-calls")"
pass
[[ "$(count "$t/model-calls")" == "$((calls + 1))" ]] || fails 'rearmed head was not reviewed'
footer | grep -qF 'hold 1 of 2:' || fails "rearmed count did not restart: $(footer)"
# A second rearm replaces the marker in place with the current total.
"$here/pr-redteam" rearm acme/widget-shop 7 >> "$t/log" 2>&1
jq -e '.holds == 3' "$t/state/rearm/acme_widget-shop-7" >/dev/null || fails 'second rearm did not record the new total'
advance; pass
footer | grep -qF 'hold 1 of 2:' || fails "after the second rearm: $(footer)"
advance; pass
footer | grep -qF 'hold 2 of 2: this PR is now left for a person' || fails "second hold after rearm: $(footer)"
advance; pass
[[ "$(count "$t/model-calls")" == "$((calls + 3))" ]] || fails 'cap did not apply again after rearm'
jq -e '.decision == "capped"' "$(receipt)" >/dev/null
echo 'ok rearm reviews the capped head and restarts the count, atomically'

# Receipts written before hold_kind existed predate the cap and do not
# count; only holds that record hold_kind "agent" do. REDTEAM_HOLD_CAP=0 turns the cap off.
REDTEAM_HOLD_CAP=0 pass
[[ "$(count "$t/model-calls")" == "$((calls + 4))" ]] || fails 'REDTEAM_HOLD_CAP=0 still capped'
footer | grep -qF '· a new push is re-reviewed</sub>' || fails "uncapped footer: $(footer)"
mkdir -p "$t/legacy/receipts/acme/widget-shop"
legacy() { # n kind-title
  jq -n --arg title "$2" '{decision:"hold",posted:true,dry_run:false,origin:"internal",
    verdict:{verdict:"block",findings:[{severity:"critical",title:$title}]}}' \
    > "$t/legacy/receipts/acme/widget-shop/9-$1.json"
}
legacy a 'jankurai/proof does not pass on this head'
legacy b 'Unpinned binary or archive (300 bytes)'
legacy c 'Client total is trusted'
legacy d 'Second legacy agent finding'
jq '.hold_kind = "agent"' "$t/legacy/receipts/acme/widget-shop/9-d.json" > "$t/legacy/d.json" \
  && mv "$t/legacy/d.json" "$t/legacy/receipts/acme/widget-shop/9-d.json"
# The count itself, from the controller's own function, over receipts for a PR with no fixture row.
n="$(REDTEAM_STATE="$t/legacy" bash -c 'source <(sed -n "/^receipt_path()/p; /^rearm_path()/p; /^agent_hold_total()/,/^}/p; /^agent_hold_count()/,/^}/p" "$1"); state="$2"; agent_hold_count acme/widget-shop 9' _ "$here/pr-redteam" "$t/legacy")"
[[ "$n" == 1 ]] || fails "counted $n agent holds, expected only the one recording hold_kind agent"
echo 'ok holds from before hold_kind do not count; the cap can be turned off'

# An approval keeps the neutral footer.
advance; approve
REDTEAM_HOLD_CAP=0 pass
footer | grep -qF "exact head \`$(head -c 12 "$t/head")\` · a new push is re-reviewed</sub>" || fails "approve footer: $(footer)"

# A proof that was pending when the agent started and failed while it ran is the quality gate's
# mechanical hold (hold_kind gate), never an agent hold, so it does not move the count.
holds_total() { REDTEAM_STATE="$t/state" bash -c 'source <(sed -n "/^agent_hold_total()/,/^}/p" "$1"); state="$2"; agent_hold_total acme/widget-shop 7' _ "$here/pr-redteam" "$t/state"; }
advance; approve
before_holds="$(holds_total)"; calls="$(count "$t/model-calls")"
touch "$t/gate-pending" "$t/gate-fails-next"
REDTEAM_HOLD_CAP=0 pass
[[ "$(count "$t/model-calls")" == "$((calls + 1))" ]] || fails 'the agent did not run while the proof was pending'
jq -e '.decision == "hold" and .hold_kind == "gate" and .posted == true' "$(receipt)" >/dev/null \
  || fails "mid-review red proof: $(cat "$(receipt)")"
[[ "$(holds_total)" == "$before_holds" ]] || fails 'a gate hold counted as an agent hold'
rm -f "$t/gate-failing"
echo 'ok a proof that fails while the agent runs is a gate hold, not counted'

# The same at the cap: no agent, and a proof that fails during the attempt holds as the gate, not
# as the cap.
advance
calls="$(count "$t/model-calls")"
touch "$t/gate-pending" "$t/gate-fails-next"
pass
[[ "$(count "$t/model-calls")" == "$calls" ]] || fails 'the agent ran at the cap'
jq -e '.decision == "hold" and .hold_kind == "gate" and .posted == true
    and .verdict.findings[0].title == "jankurai/proof does not pass on this head"' "$(receipt)" >/dev/null \
  || fails "capped head with a red proof: $(cat "$(receipt)")"
[[ "$(holds_total)" == "$before_holds" ]] || fails 'a capped gate hold counted as an agent hold'
rm -f "$t/gate-failing"
echo 'ok a capped head whose proof fails during the attempt is a gate hold'

# A capped head cannot land until the agent reviews it; once a rearm lets the agent approve that
# same head, the approval replaces the cap's own request for changes and the head lands.
advance; approve
pass
jq -e '.decision == "capped" and .posted == true' "$(receipt)" >/dev/null || fails 'expected a capped head'
[[ "$(changes_requested_now)" == 1 ]] || fails 'the capped review did not request changes'
REDTEAM_MERGE_TOKEN_FILE="$t/token" "$here/pr-redteam" _merge >> "$t/log" 2>&1
[[ ! -e "$t/merged" ]] || fails 'a capped head was merged'
"$here/pr-redteam" rearm acme/widget-shop 7 >> "$t/log" 2>&1
pass
jq -e '.decision == "approve" and .posted == true' "$(receipt)" >/dev/null || fails 'the rearmed head was not approved'
[[ "$(changes_requested_now)" == 0 ]] || fails 'the approval did not replace the request for changes'
REDTEAM_MERGE_TOKEN_FILE="$t/token" "$here/pr-redteam" _merge >> "$t/log" 2>&1
jq -e --arg sha "$(cat "$t/head")" '.expected_head_sha == $sha' "$t/merged" >/dev/null || fails 'the rearmed, approved head did not land'
echo 'ok a capped head lands only after a rearm and an agent approval of that head'
[[ ! -e "$t/danger" ]] || fails "$(cat "$t/danger")"
if grep -RFq 'fixture-bearer' "$t/state" "$t/log"; then fails 'credential leaked'; fi
echo 'ok an approval keeps the neutral footer'
echo 'HOLD CAP PASS'
