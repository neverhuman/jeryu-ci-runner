#!/usr/bin/env bash
# The 30-second poke, against stand-in forge/model/systemd processes: it starts a pass early, once
# per head, for a head nobody reviewed and for an approval that became landable, and it never
# reviews, merges or starts anything on a dry run.
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
  else printf '{"checks":[{"name":"jeryu-deploy/required","required":true,"conclusion":"success"}]}\n200'; fi
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
  */pulls/107) row | jq -c '. + {merge_passport:{blockers:[]}}'; printf '\n200' ;;
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
export JERYU_BASE=https://forge.invalid
count() { if [[ -f "$1" ]]; then wc -l < "$1"; else echo 0; fi; }
cat > "$t/bin/systemctl" <<'FIXTURE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MERGE_FIXTURE/systemctl"
case "$*" in
  *is-active*) exit 3 ;;
  '--user start --no-block pr-redteam.service') exit 0 ;;
  *) echo "unexpected systemctl $*" >> "$MERGE_FIXTURE/danger"; exit 97 ;;
esac
FIXTURE
chmod +x "$t/bin/systemctl"
poke() { "$here/pr-redteam" poke "$@" >> "$t/controller.log" 2>&1; }
pass() { "$here/pr-redteam" run --repo jeryu/fixture --pr 107 >> "$t/controller.log" 2>&1; }
starts() { if [[ -f "$t/systemctl" ]]; then grep -c '^--user start --no-block pr-redteam.service$' "$t/systemctl" || true; else echo 0; fi; }

# A dry run says what it would do and starts nothing, and does not use up the head.
poke --dry-run
grep -q 'poke: would start a pass (review jeryu/fixture#107' "$t/controller.log"
[[ "$(starts)" == 0 ]]
echo 'ok dry run starts nothing'

# A head nobody has reviewed starts a pass, once.
rm -f "$t/state/poke-seen"
poke
[[ "$(starts)" == 1 ]]
grep -q 'poke: starting a pass now (review jeryu/fixture#107' "$t/controller.log"
poke
[[ "$(starts)" == 1 ]]
echo 'ok an unreviewed head starts one pass'

# Reviewed and approved while its required context fails: nothing to land yet, so no pass.
touch "$t/required-failing"
pass
jq -e '.posted == true and .decision == "approve"' "$t/state/receipts/jeryu/fixture/107-$(cat "$t/head").json" > /dev/null
poke
[[ "$(starts)" == 1 ]]
echo 'ok an approval waiting on its gate starts nothing'

# The context goes green on a retry: the approval is landable now, so one pass starts to merge it.
rm "$t/required-failing"
poke
[[ "$(starts)" == 2 ]]
grep -q 'poke: starting a pass now (merge jeryu/fixture#107' "$t/controller.log"
poke
[[ "$(starts)" == 2 ]]
echo 'ok a newly landable approval starts one pass'

# Poke itself never reviewed, merged or rewrote anything.
[[ "$(count "$t/model-calls")" == 1 && "$(count "$t/merges")" == 0 && ! -e "$t/danger" ]]
echo 'POKE PASS'
