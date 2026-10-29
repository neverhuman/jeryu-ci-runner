#!/usr/bin/env bash
# The event-driven watcher, against stand-in forge/model/unit-manager processes: one long poll
# starts one scoped review per reported head, at most REDTEAM_JOBS at a time, advances its cursor
# only over heads it queued, resyncs when the forge's sequence goes backwards, refuses a scope the
# forge did not spell as a pull request head, starts nothing on a dry run, and lands nothing. The
# scoped review entrypoint reviews the named pull request's live head and no other.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
finish() { local result=$?; ((result == 0)) || tail -60 "$t/controller.log" 2>/dev/null || true; rm -rf -- "$t"; }
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
    push|rebase|--force-with-lease*) echo forbidden-history-write >> "$WATCH_FIXTURE/danger"; exit 97 ;;
    https://forge.invalid/git/jeryu/fixture.git) args+=("$WATCH_FIXTURE/repo") ;;
    *) args+=("$arg") ;;
  esac
done
exec "$FIXTURE_REAL_GIT" "${args[@]}"
FIXTURE
cat > "$t/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
method=GET data='' bearer='' url=''
printf '%s\n' "$@" > "$WATCH_FIXTURE/argv"
if grep -Eq 'fixture-bearer' "$WATCH_FIXTURE/argv"; then
  printf 'bearer in curl argv\n' >> "$WATCH_FIXTURE/danger"; exit 95
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
printf '%s %s\n' "$method" "$url" >> "$WATCH_FIXTURE/requests"
if [[ "$bearer" != "$(cat "$WATCH_FIXTURE/token")" ]]; then
  printf 'wrong identity for %s\n' "$url" >> "$WATCH_FIXTURE/danger"; exit 96
fi
row() {
  jq -nc --arg sha "$(cat "$WATCH_FIXTURE/head")" --arg base "$(cat "$WATCH_FIXTURE/base")" \
    '{repo:{owner:"jeryu",name:"fixture"},number:107,head_sha:$sha,base_sha:$base,head_ref:"topic",
      base_ref:"main",draft:false,author:"contributor",title:"fixture",body_markdown:"fixture",
      state:"open",labels:["origin:internal"],passport_hash:"fixture-passport",review:{changes_requested:0},
      mergeable:{can_merge:true,reason:"ready"}}'
}
case "$url" in
  */api/v3/user) printf '{"login":"independent-reviewer"}\n200' ;;
  */api/v1/review-wanted*)
    # Each answer file is one long poll's answer, consumed in order.
    next="$(ls "$WATCH_FIXTURE"/answers/* 2>/dev/null | head -1)"
    if [[ -z "$next" ]]; then printf '{"seq":0,"signals":[]}\n200'; exit 0; fi
    code="$(sed -n 1p "$next")"; body="$(sed -n '2,$p' "$next")"; rm -f "$next"
    printf '%s\n%s' "$body" "$code" ;;
  */api/v1/repos) printf '{"repositories":[{"id":{"owner":"jeryu","name":"fixture"},"family":"jain","open_pull_requests":1}]}\n200' ;;
  *'/pulls?state=open') row | jq -c '{items:[.]}'; printf '\n200' ;;
  */pulls/107)
    row | jq -c '. + {merge_passport:{head_sha:.head_sha, blockers:[]}}'; printf '\n200' ;;
  */pulls/107/checks) printf '{"checks":[{"name":"jeryu-deploy/required","required":true,"conclusion":"success"}]}\n200' ;;
  */reviews) jq -c . <<< "$data" >> "$WATCH_FIXTURE/posts"; printf '{"ok":true}\n201' ;;
  */check-runs) jq -c . <<< "$data" >> "$WATCH_FIXTURE/check-runs"; printf '{"id":"check-run-fixture"}\n201' ;;
  */merge|*/queue) printf 'merge from the watcher\n' >> "$WATCH_FIXTURE/danger"; exit 94 ;;
  *) printf 'forbidden API %s\n' "$url" >> "$WATCH_FIXTURE/danger"; exit 98 ;;
esac
FIXTURE
cat > "$t/bin/model" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then echo '9.9.9 (Claude Code)'; exit 0; fi
WATCH_FIXTURE="$(dirname "$(dirname "$0")")"
printf 'called\n' >> "$WATCH_FIXTURE/model-calls"
printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"verdict":"approve","summary":"fixture review complete","findings":[]}}\n'
FIXTURE
cat > "$t/bin/systemctl" <<'FIXTURE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WATCH_FIXTURE/systemctl"
case "$*" in
  *list-units*pr-redteam-review@*)
    busy="$(cat "$WATCH_FIXTURE/busy-slots" 2>/dev/null || echo 0)"
    for ((i = 0; i < busy; i++)); do
      printf 'pr-redteam-review@jeryu:fixture:%s:1111111111111111111111111111111111111111.service loaded active running\n' "$((900 + i))"
    done
    exit 0 ;;
  '--user start --no-block pr-redteam-review@'*) [[ ! -e "$WATCH_FIXTURE/start-failed" ]] ;;
  *is-active*) exit 3 ;;
  *) echo "unexpected systemctl $*" >> "$WATCH_FIXTURE/danger"; exit 97 ;;
esac
FIXTURE
chmod +x "$t/bin/"*
mkdir -p "$t/answers"
export WATCH_FIXTURE="$t" FIXTURE_REAL_GIT="$real_git"
export PATH="$t/bin:$PATH" JERYU_TOKEN_FILE="$t/token"
export REDTEAM_STATE="$t/state" REDTEAM_CLAUDE="$t/bin/model" REDTEAM_CLAUDE_VERSION=9.9.9 REDTEAM_TIMEOUT=10
export JERYU_BASE=https://forge.invalid
head_sha="$(cat "$t/head")"
answer() { printf '%s\n%s\n' "$1" "$2" > "$t/answers/$(date +%s%N)"; }
watch() { "$here/pr-redteam" watch --once "$@" >> "$t/controller.log" 2>&1; }
starts() { if [[ -f "$t/systemctl" ]]; then grep -c '^--user start --no-block pr-redteam-review@' "$t/systemctl" || true; else echo 0; fi; }
cursor() { cat "$t/state/watch-cursor" 2>/dev/null || echo none; }
queued() { if [[ -f "$t/state/watch-queue" ]]; then wc -l < "$t/state/watch-queue"; else echo 0; fi; }

signal() { # seq kind sha
  jq -nc --argjson seq "$1" --arg kind "$2" --arg sha "$3" \
    '{seq:$seq,signals:[{seq:$seq,repo:"jeryu/fixture",number:107,head_sha:$sha,base_ref:"main",draft:false,kind:$kind,at:"2026-10-29T09:00:00Z"}]}'
}

# A dry run says what it would do, starts nothing and remembers nothing.
answer 200 "$(signal 4 pull.opened "$head_sha")"
watch --dry-run
grep -q "watch: pull.opened jeryu/fixture#107 ${head_sha:0:12}" "$t/controller.log"
[[ "$(starts)" == 0 && "$(cursor)" == none && "$(queued)" == 0 ]]
echo 'ok a dry run starts nothing and advances nothing'

# A reported head starts exactly one scoped review unit, and the cursor stops asking for it.
answer 200 "$(signal 4 pull.opened "$head_sha")"
watch
[[ "$(starts)" == 1 && "$(cursor)" == 4 && "$(queued)" == 0 ]]
grep -qxF -- "--user start --no-block pr-redteam-review@jeryu:fixture:107:$head_sha.service" "$t/systemctl"
# The same head reported again (a repeated signal after a crash) starts the same scoped unit, which
# the per-PR review lock makes a no-op; nothing else is started.
answer 200 "$(signal 5 pull.synchronized "$head_sha")"
watch
[[ "$(starts)" == 2 && "$(cursor)" == 5 ]]
echo 'ok a reported head starts one scoped review'

# The worker pool is a bound: with every slot busy the head waits in the queue instead of starting
# a review, and the next poll starts it once a slot frees.
printf '4\n' > "$t/busy-slots"
answer 200 "$(signal 6 pull.synchronized "$head_sha")"
watch
[[ "$(starts)" == 2 && "$(queued)" == 1 && "$(cursor)" == 6 ]]
grep -q 'slots busy' "$t/controller.log"
printf '0\n' > "$t/busy-slots"
answer 200 '{"seq":6,"signals":[]}'
watch
[[ "$(starts)" == 3 && "$(queued)" == 0 ]]
echo 'ok a full pool queues the head and starts it when a slot frees'

# A failed start keeps the head queued for the next poll.
touch "$t/start-failed"
answer 200 "$(signal 7 pull.opened "$head_sha")"
watch
[[ "$(starts)" == 4 && "$(queued)" == 1 ]]
grep -q 'could not start pr-redteam-review@' "$t/controller.log"
rm "$t/start-failed"
answer 200 '{"seq":7,"signals":[]}'
watch
[[ "$(starts)" == 5 && "$(queued)" == 0 ]]
echo 'ok a failed start keeps the head for the next poll'

# A sequence that went backwards is a restarted forge, not a backlog: resync, replay nothing.
answer 200 '{"seq":2,"signals":[{"seq":2,"repo":"jeryu/fixture","number":107,"head_sha":"'"$head_sha"'","base_ref":"main","draft":false,"kind":"pull.opened","at":"2026-10-29T09:00:00Z"}]}'
watch
[[ "$(starts)" == 5 && "$(cursor)" == 2 && "$(queued)" == 0 ]]
grep -q 'sequence went back to 2' "$t/controller.log"
echo 'ok a smaller sequence resyncs without replaying'

# Anything that is not exactly owner/name, a positive number and a 40-hex head is not a scope.
answer 200 '{"seq":9,"signals":[
  {"seq":8,"repo":"jeryu/fixture;rm -rf","number":107,"head_sha":"'"$head_sha"'","kind":"pull.opened"},
  {"seq":9,"repo":"jeryu/fixture","number":107,"head_sha":"../../etc/passwd","kind":"pull.opened"}]}'
watch
[[ "$(starts)" == 5 && "$(queued)" == 0 && "$(cursor)" == 9 ]]
grep -q 'not a reviewable scope' "$t/controller.log"
echo 'ok a scope the forge did not spell as a head starts nothing'

# A forge that answers something else leaves the cursor alone; the pass remains the fallback.
answer 503 '{"message":"unavailable"}'
REDTEAM_STATE="$t/state" watch
[[ "$(cursor)" == 9 && "$(starts)" == 5 ]]
grep -q 'answered 503 for review-wanted' "$t/controller.log"
echo 'ok a forge error changes nothing'

# The scoped entrypoint reviews the pull request it was given and refuses every other scope.
"$here/pr-redteam" _review_scoped "other:fixture:107:$head_sha" >> "$t/controller.log" 2>&1
"$here/pr-redteam" _review_scoped 'jeryu:fixture:108:1111111111111111111111111111111111111111' >> "$t/controller.log" 2>&1
[[ ! -f "$t/model-calls" ]]
"$here/pr-redteam" _review_scoped "jeryu:fixture:107:$head_sha" >> "$t/controller.log" 2>&1
[[ "$(wc -l < "$t/model-calls")" == 1 ]]
jq -e '.posted == true and .decision == "approve"' "$t/state/receipts/jeryu/fixture/107-$head_sha.json" > /dev/null
# Nothing was merged, and the watcher never asked to.
[[ ! -e "$t/danger" && ! -e "$t/merges" ]]
echo 'ok the scoped review reviews its own head and lands nothing'
echo 'WATCH PASS'
