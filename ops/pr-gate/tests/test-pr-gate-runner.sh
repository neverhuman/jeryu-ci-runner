#!/usr/bin/env bash
# Full runner protocol test: real Git/processes, synthetic local forge and token.
set -euo pipefail
# A gate may run this suite inside a pr-gate-runner whose environment reaches the recipe. Its
# GATE_RUNNER_*/JERYU_*/PR_GATE_* variables would then steer the runner under test: GATE_RUNNER_SLOT=1
# put the tree at tree-slot1/ while the assertions read tree/. Start clean, and never read the host's
# own site configuration: this suite brings its own (invented) one.
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/tools" "$fixture/runtime" "$fixture/vendor"
real_git=$(command -v git)
printf '%s\n' "$real_git" >"$fixture/real-git"
git init -q --initial-branch=main "$fixture/source"
git -C "$fixture/source" config user.name Fixture
git -C "$fixture/source" config user.email fixture@example.invalid
printf 'target/\n' >"$fixture/source/.gitignore"
printf 'pass\n' >"$fixture/source/mode"
git -C "$fixture/source" add .
git -C "$fixture/source" commit -qm fixture
git clone -q --bare --no-local "$fixture/source" "$fixture/source.git"
git -C "$fixture/source" rev-parse HEAD >"$fixture/head"
printf 'synthetic-fixture-token\n' >"$fixture/token"
chmod 0600 "$fixture/token"
cat >"$fixture/tools/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
case " $* " in
  *' fetch '*|*' clone '*|*' ls-remote '*)
    for index in "${!args[@]}"; do
      case "${args[$index]}" in
        https://forge.invalid/git/acme/fixture.git|https://forge.invalid/git/gate-a/hubDB.git) args[$index]="$FAKE_FORGE/source.git";;
        https://forge.invalid/git/acme/*.git)
          name=${args[$index]##*/}; args[$index]="$FAKE_FORGE/${name%.git}.git";;
      esac
    done;;
esac
exec "$REAL_GIT" "${args[@]}"
SH
cat >"$fixture/tools/just" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --summary ]]; then [[ -f "$FAKE_FORGE/no-recipe" ]] || printf 'required\n'; exit; fi
[[ "${1:-}" == required ]]
fixture_root="$(cd "$(dirname "$0")/.." && pwd)"
worker_git="$(cat "$fixture_root/real-git")"
expected_repository=acme/fixture
[[ ! -f "$fixture_root/expected-repository" ]] || read -r expected_repository <"$fixture_root/expected-repository"
expected_mirror="$fixture_root/runner/mirror/fixture.git"
[[ "$expected_repository" != gate-a/hubDB ]] || expected_mirror="$fixture_root/runner/mirror/gate-a/hubDB.git"
# Product source-authority checks require both URLs to identify the hosted source.
[[ "$("$worker_git" remote get-url origin)" == "https://forge.invalid/git/$expected_repository.git" ]] \
  || { printf 'worker fetch origin is not canonical\n' >&2; exit 31; }
[[ "$("$worker_git" remote get-url --push origin)" == "https://forge.invalid/git/$expected_repository.git" ]] \
  || { printf 'worker push origin is not canonical\n' >&2; exit 32; }
[[ "$("$worker_git" remote get-url cache-mirror)" == "$expected_mirror" ]] \
  || { printf 'worker cache mirror is not separately named\n' >&2; exit 33; }
mkdir -p target
# The counter lives beside the fake forge, not in target/: a repository that does not share the build
# directory has target/ rebuilt from scratch for every gate, which would erase it.
count=0
[[ ! -f "$fixture_root/executions" ]] || read -r count <"$fixture_root/executions"
printf '%s\n' "$((count + 1))" >"$fixture_root/executions"
printf 'error: expected rejection in a passing negative test\n'
[[ "$(cat mode)" == pass ]] || exit 7
SH
cat >"$fixture/tools/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
method=GET payload='{}'
while (($#)); do
  case "$1" in -X) method=$2; shift 2;; --data) payload=$2; shift 2;; *) url=$1; shift;; esac
done
head=$(cat "$FAKE_FORGE/head")
case "$method $url" in
  'GET '*'/pulls?state=open')
    jq -nc --arg sha "$head" '{items:[{number:1,head_sha:$sha}]}'
    printf '\n200';;
  'GET '*'/pulls/1')
    count=0
    [[ ! -f "$FAKE_FORGE/head-reads" ]] || read -r count <"$FAKE_FORGE/head-reads"
    count=$((count + 1)); printf '%s\n' "$count" >"$FAKE_FORGE/head-reads"
    if [[ -f "$FAKE_FORGE/change-head" && "$count" -gt 1 ]]; then head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; fi
    jq -nc --arg sha "$head" '{state:"open",user:{login:"author"},head:{sha:$sha,ref:"author/feature"}}'
    printf '\n200';;
  'GET '*'/branches/main/protection')
    jq -nc '{required_status_checks:{contexts:["fixture/required"]}}'
    printf '\n200';;
  'GET '*'/gate-regate'*)
    if [[ -f "$FAKE_FORGE/refuse-regate" ]]; then printf '{"message":"re-gate list denied"}\n403'; exit; fi
    if [[ -f "$FAKE_FORGE/regate.json" ]]; then cat "$FAKE_FORGE/regate.json"; else printf '{"requests":[]}'; fi
    printf '\n200';;
  'GET '*'/merge-queue?state=building')
    if [[ -f "$FAKE_FORGE/queue.json" ]]; then cat "$FAKE_FORGE/queue.json"; else printf '{"entries":[]}'; fi
    printf '\n200';;
  'GET '*'/status')
    # Statuses are per commit, as on the forge; a hand-written row without a sha applies to any.
    commit=${url%/status}; commit=${commit##*/}
    if [[ -f "$FAKE_FORGE/statuses.jsonl" ]]; then
      jq -sc --arg c "$commit" '{statuses:[.[] | select(.sha == null or .sha == $c)]}' "$FAKE_FORGE/statuses.jsonl"
    else printf '{"statuses":[]}'; fi
    printf '\n200';;
  'POST '*'/statuses/'*)
    if [[ -f "$FAKE_FORGE/reject-terminal" && "$(jq -r '.state' <<<"$payload")" != pending ]]; then
      printf '{"message":"publication denied"}\n403'; exit
    fi
    count=0
    [[ ! -f "$FAKE_FORGE/statuses.jsonl" ]] || count=$(wc -l <"$FAKE_FORGE/statuses.jsonl")
    result=$(jq -c --arg id "status-$count" --argjson clock "$count" --arg sha "${url##*/statuses/}" \
      '. + {id:$id,updated_at:$clock,sha:$sha}' <<<"$payload")
    printf '%s\n' "$result" >>"$FAKE_FORGE/statuses.jsonl"
    printf '%s\n201' "$result";;
  'POST '*'/check-runs')
    if [[ -f "$FAKE_FORGE/reject-check-run" ]]; then printf '{"message":"check runs unavailable"}\n500'; exit; fi
    printf '{"id":"check"}\n201';;
  'POST '*'/heartbeat')
    printf '%s\n' "$payload" >>"$FAKE_FORGE/heartbeats.jsonl"
    if [[ -f "$FAKE_FORGE/reject-heartbeat-tools" ]] && jq -e 'has("tools")' <<<"$payload" >/dev/null; then
      printf 'Failed to deserialize the JSON body: unknown field `tools`\n422'; exit
    fi
    if [[ -f "$FAKE_FORGE/reject-heartbeat-code" ]] && jq -e 'has("code")' <<<"$payload" >/dev/null; then
      printf 'Failed to deserialize the JSON body: unknown field `code`\n422'; exit
    fi
    printf '{"accepted":true}\n200';;
  *) printf '{"message":"unexpected fixture route"}\n404';;
esac
SH
chmod +x "$fixture/tools/"*
export FAKE_FORGE="$fixture" REAL_GIT="$real_git"
# The site configuration, as a gate host keeps it: read as KEY=VALUE lines, never run.
cat >"$fixture/pr-gate.env" <<ENV
# invented site for this suite
PR_GATE_FORGE_URL="https://forge.invalid"
JERYU_TOKEN_FILE=$fixture/token
GATE_RUNNER_IDENTITY='runner-bot'
PR_GATE_PRIMARY_OWNER=acme
PR_GATE_CONTEXT_OVERRIDES="gate-a/hubDB=hub/required"
PR_GATE_CODE_REPO=example/gate-code
PATH=/nonexistent-from-config
ENV
export PR_GATE_CONFIG="$fixture/pr-gate.env"
export GATE_RUNNER_HOME="$fixture/runner" GATE_RUNNER_TOOLS="$fixture/tools"
export GATE_RUNNER_RUNTIME_TOOLS="$fixture/runtime" GATE_RUNNER_NATIVE_VENDOR="$fixture/vendor"
export GATE_RUNNER_REPOS=acme/fixture GATE_RUNNER_FAMILY=fixture GATE_RUNNER_SCCACHE=""
export GATE_RUNNER_SLOT=0   # the tree path the assertions read
export GATE_RUNNER_REGATE_SETTLE=0   # re-gate coalescing is exercised on its own at the end
export PATH="$fixture/tools:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
invoke() {
  runner_exit=0
  bash "$script_dir/pr-gate-runner.sh" "$@" >"$fixture/runner.log" 2>&1 || runner_exit=$?
}
count() { cat "$fixture/executions" 2>/dev/null || printf 'none\n'; }
# Every count assertion says what actually happened; a bare [[ ]] left no trace of the runner's own
# decision when this suite failed inside a gate.
expect_count() {
  local want=$1 got; got=$(count)
  [[ "$got" == "$want" ]] && return
  printf 'expected %s recipe executions, got %s\n--- runner.log\n' "$want" "$got" >&2
  cat "$fixture/runner.log" >&2
  printf -- '--- statuses\n' >&2
  cat "$fixture/statuses.jsonl" 2>/dev/null >&2 || true
  printf -- '--- tree\n' >&2
  ls -la "$fixture/runner/tree/fixture" 2>/dev/null >&2 || true
  exit 1
}
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count 1
jq -se 'last.state=="success"' "$fixture/statuses.jsonl" >/dev/null
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count 1
printf 'PASS complete runner: negative-test log is success; identical receipt reuses\n'

touch "$fixture/change-head"
rm -f "$fixture/head-reads"
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count 1
grep -q 'head changed or PR closed' "$fixture/runner.log"
rm -f "$fixture/change-head"
printf 'PASS complete runner: changed PR head refuses dispatch\n'

printf 'fail\n' >"$fixture/source/mode"
"$real_git" -C "$fixture/source" add mode
"$real_git" -C "$fixture/source" commit -qm fail-fixture
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }   # a recorded red gate is not a runner fault
expect_count 2
jq -se 'last.state=="failure"' "$fixture/statuses.jsonl" >/dev/null
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count 2
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count 3
printf 'PASS complete runner: failure holds; explicit retry executes exactly once\n'

touch "$fixture/reject-terminal"
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 1 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count 4
grep -q 'publication recovery required' "$fixture/runner.log"
head=$(cat "$fixture/head")
jq -e '.terminal and .exit_code==7 and (.publication.required_status|not)' \
  "$fixture/runner/attempts/acme-fixture-$head/last-result.json" >/dev/null
rm -f "$fixture/reject-terminal"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count 4
jq -se 'last.state=="failure"' "$fixture/statuses.jsonl" >/dev/null
printf 'PASS complete runner: rejected terminal publication recovers without rerun\n'

# The shared target decides freshness by mtime, so the checkout must stamp every tracked file: an
# unchanged file older than another tree's build would let cargo reuse that build.
tree="$fixture/runner/tree/fixture"
touch -h -d '2000-01-01 00:00:00' "$tree/mode" "$tree/.gitignore"
"$real_git" -C "$tree" update-index -q --refresh   # the index now agrees: git sees nothing to rewrite
touch "$fixture/stamp"
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count 5
[[ "$tree/mode" -nt "$fixture/stamp" && "$tree/.gitignore" -nt "$fixture/stamp" ]] \
  || { printf 'tracked files kept stale mtimes\n' >&2; exit 1; }
printf 'PASS complete runner: checkout stamps every tracked file for the shared target\n'

# A rejected check run is not a required context: it is recorded, and it neither holds the attempt in
# recovery nor stops the next tick.
printf 'pass\n' >"$fixture/source/mode"
"$real_git" -C "$fixture/source" add mode
"$real_git" -C "$fixture/source" commit -qm pass-again
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
touch "$fixture/reject-check-run"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
head=$(cat "$fixture/head")
jq -se 'last.state=="success"' "$fixture/statuses.jsonl" >/dev/null
jq -e '.publication.required_status and (.publication.check_run|not) and (.recovery_required|not)' \
  "$fixture/runner/attempts/acme-fixture-$head/last-result.json" >/dev/null
rm -f "$fixture/reject-check-run"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
if grep -q 'recovery required' "$fixture/runner.log"; then
  printf 'the runner asked for recovery after a rejected check run\n' >&2
  cat "$fixture/runner.log" >&2
  exit 1
fi
printf 'PASS complete runner: a rejected check run is recorded and never wedges the gate\n'

# A head whose repository has no gate recipe gets a failure status, and the tick keeps going.
touch "$fixture/no-recipe"
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
jq -se 'last.state=="failure" and (last.description|test("no gate"))' "$fixture/statuses.jsonl" >/dev/null
grep -q 'neither a required recipe nor' "$fixture/runner.log"
rm -f "$fixture/no-recipe"
printf 'PASS complete runner: a head with no recipe fails honestly without stopping the tick\n'

# By default a repository builds in its own real target directory: the family's containment and
# coverage checks refuse a symlinked one.
[[ ! -L "$fixture/runner/tree/fixture/target" && -d "$fixture/runner/tree/fixture/target" ]] \
  || { printf 'target is not a real directory by default\n' >&2; exit 1; }
# A repository on the unshared list builds in its own tree, and that tree's target is rebuilt from
# scratch, so no earlier commit's objects or coverage profiles can be counted. The execution count
# therefore restarts at 1, and a planted stale artifact is gone.
printf 'unshared\n' >"$fixture/source/marker"
"$real_git" -C "$fixture/source" add marker
"$real_git" -C "$fixture/source" commit -qm unshared-fixture
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
mkdir -p "$fixture/runner/tree/fixture"
export GATE_RUNNER_SHARED_TARGETS=other-repo   # this fixture is deliberately NOT opted in
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
[[ ! -L "$fixture/runner/tree/fixture/target" && -d "$fixture/runner/tree/fixture/target" ]] \
  || { printf 'target stayed a symlink for an unshared repository\n' >&2; exit 1; }
grep -q 'builds in its own clean tree' "$fixture/runner.log"
printf 'stale\n' >"$fixture/runner/tree/fixture/target/stale-profile"
printf 'pass\n' >"$fixture/source/mode"
printf 'again\n' >"$fixture/source/marker"
"$real_git" -C "$fixture/source" add marker mode
"$real_git" -C "$fixture/source" commit -qm unshared-again
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
invoke
unset GATE_RUNNER_SHARED_TARGETS
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
[[ ! -e "$fixture/runner/tree/fixture/target/stale-profile" ]] \
  || { printf 'the unshared tree kept a previous gate artifact\n' >&2; exit 1; }
printf 'PASS complete runner: an unshared repository builds in its own tree, cleaned each gate\n'

# An unpublishable head is left for the next tick instead of stopping the whole tick, and its receipt
# is not carried into another commit's gate.
touch "$fixture/reject-terminal"
invoke --repo acme/fixture --pr 1          # records terminal evidence that cannot be published
[[ "$runner_exit" == 1 ]] || { cat "$fixture/runner.log"; exit 1; }
invoke                                      # the next tick must not die in gate_recover
[[ "$runner_exit" == 0 ]] || { printf 'a head with unpublished evidence stopped the tick\n' >&2; cat "$fixture/runner.log"; exit 1; }
grep -q 'leaving it for the next tick' "$fixture/runner.log"
rm -f "$fixture/reject-terminal"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
printf 'PASS complete runner: an unpublishable head is left for the next tick, not fatal\n'

# A family sibling with no canonical main is skipped, not fatal: a repository with only a scaffold
# branch once made a fatal mirror step stop every gate of its family before any commit was tested.
git init -q --initial-branch=scaffold "$fixture/nomain-src"
git -C "$fixture/nomain-src" config user.name Fixture
git -C "$fixture/nomain-src" config user.email fixture@example.invalid
printf 'scaffold\n' >"$fixture/nomain-src/file"
git -C "$fixture/nomain-src" add file
git -C "$fixture/nomain-src" commit -qm scaffold
git clone -q --bare --no-local "$fixture/nomain-src" "$fixture/nomain.git"
printf 'again\n' >>"$fixture/source/marker"
"$real_git" -C "$fixture/source" add marker
"$real_git" -C "$fixture/source" commit -qm with-a-mainless-sibling
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
export GATE_RUNNER_FAMILY="fixture nomain"
invoke
export GATE_RUNNER_FAMILY=fixture
[[ "$runner_exit" == 0 ]] || { printf 'a sibling without main stopped the gate\n' >&2; cat "$fixture/runner.log"; exit 1; }
grep -q 'has no canonical main' "$fixture/runner.log"
[[ ! -d "$fixture/runner/mirror/nomain.git" ]] || { printf 'a mirror was left behind for a repository with no main\n' >&2; exit 1; }
# The same holds when a mirror already exists and main disappears upstream: no stale mirror may remain
# for step 3 to check out.
git clone -q --bare --no-local "$fixture/nomain-src" "$fixture/runner/mirror/nomain.git"
git -C "$fixture/runner/mirror/nomain.git" branch -q main scaffold
export GATE_RUNNER_FAMILY="fixture nomain"
invoke
export GATE_RUNNER_FAMILY=fixture
[[ "$runner_exit" == 0 ]] || { printf 'a sibling whose main vanished stopped the gate\n' >&2; cat "$fixture/runner.log"; exit 1; }
[[ ! -d "$fixture/runner/mirror/nomain.git" ]] || { printf 'a stale mirror survived a vanished main\n' >&2; exit 1; }
jq -se 'last.state=="success"' "$fixture/statuses.jsonl" >/dev/null
printf 'PASS complete runner: a sibling with no canonical main is skipped, not fatal\n'

# No-main cleanup must not consume a run path inherited from the parent or a prior owner.
# The runner assigns the current owner's tree only after mirror preparation.
mkdir -p "$fixture/previous-owner-tree/nomain"
printf 'preserve prior owner evidence\n' >"$fixture/previous-owner-tree/nomain/evidence"
export GATE_RUNNER_FAMILY="fixture nomain"
run="$fixture/previous-owner-tree" invoke
export GATE_RUNNER_FAMILY=fixture
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
[[ -f "$fixture/previous-owner-tree/nomain/evidence" ]] \
  || { printf 'no-main cleanup deleted the inherited previous-owner tree\n' >&2; exit 1; }
printf 'PASS complete runner: missing main never deletes an inherited previous-owner tree\n'

# A previously populated slot must not retain a sibling whose canonical main disappeared.
# No recipe or publication is allowed against its old source, even after its mirror was dropped.
git clone -q --no-local "$fixture/nomain-src" "$fixture/runner/tree/nomain"
status_count=$(wc -l <"$fixture/statuses.jsonl")
export GATE_RUNNER_FAMILY="fixture nomain"
invoke
export GATE_RUNNER_FAMILY=fixture
[[ "$runner_exit" != 0 ]] || { printf 'a stale sibling checkout was admitted without canonical main\n' >&2; cat "$fixture/runner.log"; exit 1; }
grep -q 'stale sibling checkout without canonical main' "$fixture/runner.log"
[[ "$(wc -l <"$fixture/statuses.jsonl")" == "$status_count" ]] \
  || { printf 'a stale sibling attempt published a status\n' >&2; exit 1; }
printf 'PASS complete runner: a prior sibling checkout without canonical main is refused before dispatch\n'

# A sibling the forge cannot serve at all stays fatal: only a proven absence of main is tolerated.
export GATE_RUNNER_FAMILY="fixture unreachable"
invoke
export GATE_RUNNER_FAMILY=fixture
[[ "$runner_exit" != 0 ]] || { printf 'an unreachable sibling did not stop the gate\n' >&2; cat "$fixture/runner.log"; exit 1; }
grep -q 'cannot mirror canonical main for acme/unreachable' "$fixture/runner.log"
printf 'PASS complete runner: an unreachable sibling is still fatal\n'

# Opting a repository in gives it the shared per-repo build directory, reached through the symlink.
printf 'shared\n' >>"$fixture/source/marker"
"$real_git" -C "$fixture/source" add marker
"$real_git" -C "$fixture/source" commit -qm shared-opt-in
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
export GATE_RUNNER_SHARED_TARGETS="acme/fixture"
invoke
unset GATE_RUNNER_SHARED_TARGETS
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
[[ -L "$fixture/runner/tree/fixture/target" ]] \
  || { printf 'an opted-in repository did not get the shared build directory\n' >&2; exit 1; }
[[ "$(readlink "$fixture/runner/tree/fixture/target")" == "$fixture/runner/targets/acme/fixture" ]]
printf 'PASS complete runner: sharing a build directory is opt in, and the opt-in works\n'

# A hub repository's protected context follows its manifest name (PR_GATE_CONTEXT_OVERRIDES), not its forge slug.
# Exercise the real worker and durable publication/reuse paths, with no manual green status.
printf 'gate-a/hubDB\n' >"$fixture/expected-repository"
export GATE_RUNNER_REPOS=gate-a/hubDB GATE_RUNNER_FAMILY=hubDB
before_count=$(count)
before_statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 1))"
if ! tail -n +"$((before_statuses + 1))" "$fixture/statuses.jsonl" \
  | jq -se 'length==2 and all(.context=="hub/required") and .[0].state=="pending" and .[1].state=="success"'; then
  printf 'hub publication did not use its protected hub/required context\n' >&2
  exit 1
fi
hub_key="$fixture/runner/attempts/gate-a-hubDB-$(cat "$fixture/head")"
jq -e '.inputs.required_context=="hub/required" and .terminal and .exit_code==0' "$hub_key/last-result.json" >/dev/null
invoke
expect_count "$((before_count + 1))"
grep -q 'reuse gate-a/hubDB' "$fixture/runner.log"
printf 'PASS hub: same-context success reused\n'
# A later failure in another context does not invalidate this independently successful context.
printf '{"id":"other","context":"unrelated/required","state":"failure","updated_at":900000}\n' >>"$fixture/statuses.jsonl"
invoke
expect_count "$((before_count + 1))"
# A later failure in the actual protected context does invalidate reuse.
clock=$(wc -l <"$fixture/statuses.jsonl")
jq -nc --argjson clock "$clock" '{id:"later",context:"hub/required",state:"failure",updated_at:$clock}' >>"$fixture/statuses.jsonl"
invoke
expect_count "$((before_count + 2))"
printf 'PASS hub: independent context ignored and later mapped failure rerun\n'
# Rejected terminal publication is retained and recovered at the admitted context.
touch "$fixture/reject-terminal"
invoke --repo gate-a/hubDB --pr 1
[[ "$runner_exit" != 0 ]]
expect_count "$((before_count + 3))"
rm "$fixture/reject-terminal"
invoke
expect_count "$((before_count + 3))"
jq -se 'last.context=="hub/required" and last.state=="success"' "$fixture/statuses.jsonl" >/dev/null
printf 'PASS complete runner: hub protected context, independent reuse, later failure and publication recovery\n'

# Merge queue: the forge replays an approved PR onto main as refs/queue/main/<n>; the runner gates that
# exact commit first, fetched through its ref, and posts the same context on it.
rm -f "$fixture/expected-repository"
export GATE_RUNNER_REPOS=acme/fixture GATE_RUNNER_FAMILY=fixture
"$real_git" -C "$fixture/source" checkout -q -B queue-build main
printf 'pass\n' >"$fixture/source/mode"
printf 'replayed onto main\n' >"$fixture/source/queued"
"$real_git" -C "$fixture/source" add mode queued
"$real_git" -C "$fixture/source" commit -qm queue-replay
qsha=$("$real_git" -C "$fixture/source" rev-parse HEAD)
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" "HEAD:refs/queue/main/1"
"$real_git" -C "$fixture/source" checkout -q main
queue_entry() { jq -nc --arg s "$1" --arg r "$2" --arg h "$(cat "$fixture/head")" \
  '{entries:[{repo:"acme/fixture",number:1,base:"main",queue_ref:$r,queue_sha:$s,pr_head_sha:$h}]}' >"$fixture/queue.json"; }
queue_entry "$qsha" refs/queue/main/1
before_count=$(count)
before_statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 1))"
grep -q "preparing acme/fixture#1 at $qsha (merge queue refs/queue/main/1)" "$fixture/runner.log" \
  || { printf 'the queue commit was not gated first\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
tail -n +"$((before_statuses + 1))" "$fixture/statuses.jsonl" \
  | jq -se --arg s "$qsha" 'length==2 and all(.sha==$s and .context=="fixture/required")
      and .[0].state=="pending" and .[1].state=="success"' >/dev/null \
  || { printf 'queue statuses were not pending then success on the queue sha\n' >&2; cat "$fixture/statuses.jsonl" >&2; exit 1; }
printf 'PASS merge queue: the queue commit is gated first, at its exact sha, with the same context\n'

# The forge rebuilt the entry: its ref no longer points at the listed sha, so nothing runs for it.
queue_entry 1111111111111111111111111111111111111111 refs/queue/main/1
before_count=$(count)
invoke
expect_count "$before_count"
grep -q 'merge-queue entry acme/fixture#1 moved on' "$fixture/runner.log" \
  || { printf 'a stale queue entry was not skipped\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
# A ref outside refs/queue/ is never fetched on the queue's behalf.
queue_entry "$qsha" refs/heads/main
invoke
expect_count "$before_count"
grep -q 'ignoring a malformed merge-queue entry' "$fixture/runner.log"
rm -f "$fixture/queue.json"
printf 'PASS merge queue: a rebuilt entry and a ref outside refs/queue/ are never gated\n'

# A sibling's main moving re-gates open heads automatically, but a burst is coalesced: the runner
# records the family's mains after each mirror fetch, and while they moved within the settle window an
# already-gated head waits. An explicit --repo/--pr is never deferred.
printf 'main moved\n' >"$fixture/source/moved"
"$real_git" -C "$fixture/source" add moved
"$real_git" -C "$fixture/source" commit -qm main-moves
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" HEAD:refs/heads/main
moved_main=$("$real_git" -C "$fixture/source" rev-parse HEAD)
mains="$fixture/runner/cache/mains-acme"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
grep -qx "fixture $moved_main" "$mains" \
  || { printf 'the moved main was not recorded\n' >&2; cat "$mains" "$fixture/runner.log" >&2; exit 1; }
before_count=$(count)
GATE_RUNNER_REGATE_SETTLE=3600 invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$before_count"
grep -q 'deferring re-gate of acme/fixture#1: acme mains moved within 3600s' "$fixture/runner.log" \
  || { printf 'a gated head was not deferred while mains were moving\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
grep -q 'no PR head needs gating' "$fixture/runner.log" || { cat "$fixture/runner.log" >&2; exit 1; }
GATE_RUNNER_REGATE_SETTLE=3600 invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
! grep -q 'deferring re-gate' "$fixture/runner.log"
grep -q 'preparing acme/fixture#1' "$fixture/runner.log"
touch -d '-2 hours' "$mains"
GATE_RUNNER_REGATE_SETTLE=3600 invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
! grep -q 'deferring re-gate' "$fixture/runner.log"
grep -q 'preparing acme/fixture#1' "$fixture/runner.log" \
  || { printf 'a settled head was not re-gated\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
printf 'PASS re-gate on a moved main: a burst is coalesced, explicit retry is not deferred, a settled head re-gates\n'

# A re-gate asked for on the forge (jeryu-deploy: POST /api/v1/repos/:id/pulls/:n/regate) gates a
# head again although a terminal result for it exists, and is listed as claimable even while a merge
# burst defers the automatic re-gates. It is honoured exactly once per request.
head=$(cat "$fixture/head")
regate() { # requested_at
  jq -nc --arg s "$head" --arg at "$1" \
    '{requests:[{repo:"acme/fixture",number:1,head_sha:$s,requested_at:$at,requested_by:"dana"}]}' \
    >"$fixture/regate.json"
}
regate 2026-10-04T09:00:00Z
touch "$mains"   # the family's mains just moved: an automatic re-gate would wait for the burst
listed=$(GATE_RUNNER_REGATE_SETTLE=3600 bash "$script_dir/pr-gate-runner.sh" --list 2>&1)
grep -qx "acme fixture 1 $head -" <<<"$listed" \
  || { printf 'a requested re-gate was not claimable:\n%s\n' "$listed" >&2; exit 1; }
before_count=$(count)
GATE_RUNNER_REGATE_SETTLE=3600 invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 1))"
grep -q "re-gate requested for acme/fixture#1 at $head" "$fixture/runner.log" \
  || { printf 'the re-gate was not named\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
[[ "$(cat "$fixture/runner/regate/acme-fixture-$head")" == 2026-10-04T09:00:00Z ]] \
  || { printf 'the honoured request was not recorded\n' >&2; exit 1; }
jq -se 'last.state=="success"' "$fixture/statuses.jsonl" >/dev/null
# The same request is not a second re-gate: the head goes back to waiting for the burst.
GATE_RUNNER_REGATE_SETTLE=3600 invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 1))"
grep -q 'deferring re-gate of acme/fixture#1' "$fixture/runner.log" \
  || { printf 'a honoured request was replayed\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
# Asking again is a newer request, and a newer request is another re-gate.
regate 2026-10-04T09:05:00Z
GATE_RUNNER_REGATE_SETTLE=3600 invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 2))"
# An explicit --repo/--pr reads no requests at all: it is already a retry.
regate 2026-10-04T09:10:00Z
GATE_RUNNER_REGATE_SETTLE=3600 invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 3))"
! grep -q 're-gate requested' "$fixture/runner.log"
[[ "$(cat "$fixture/runner/regate/acme-fixture-$head")" == 2026-10-04T09:05:00Z ]] \
  || { printf 'an explicit retry consumed a request it never read\n' >&2; exit 1; }
rm -f "$fixture/regate.json"
printf 'PASS a requested re-gate is claimable while a burst defers, runs once per request, and is never read by an explicit retry\n'

# A request the runner cannot trust is named and ignored, and a forge that refuses the list says so
# instead of silently ignoring every re-gate asked for.
jq -nc '{requests:[{repo:"acme/fixture","number":1,head_sha:"not-a-sha",requested_at:"2026-10-04T09:00:00Z"}]}' \
  >"$fixture/regate.json"
before_count=$(count)
GATE_RUNNER_REGATE_SETTLE=3600 invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$before_count"
grep -q 'ignoring a malformed re-gate request: acme/fixture#1' "$fixture/runner.log" \
  || { printf 'a malformed request was not named\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
rm -f "$fixture/regate.json"
touch "$fixture/refuse-regate"
GATE_RUNNER_REGATE_SETTLE=3600 invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
grep -q 're-gate requests answered 403; gating this tick without them' "$fixture/runner.log" \
  || { printf 'a refused re-gate list was silent\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
rm -f "$fixture/refuse-regate"
printf 'PASS a malformed re-gate request is named and ignored, and a refused list is reported\n'

# A missing sccache must be visible without being fatal: the gate says so once, still runs, and its
# receipt records what it actually compiled with. An explicit GATE_RUNNER_SCCACHE="" is a configured
# choice and says nothing, but still records cache "none".
# A PATH that simply drops /usr/bin would lose bash itself, so mirror the system directories as
# symlinks and leave sccache out of the mirror.
mkdir -p "$fixture/nosccache"
for entry in /usr/local/bin /usr/bin /bin; do
  [[ -d "$entry" ]] || continue
  cp -sn "$entry/"* "$fixture/nosccache/" 2>/dev/null || true
done
rm -f "$fixture/nosccache/sccache"
uncached_path="$fixture/tools:$fixture/nosccache"
printf 'no sccache\n' >>"$fixture/source/marker"
"$real_git" -C "$fixture/source" add marker
"$real_git" -C "$fixture/source" commit -qm sccache-absent
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
before_count=$(count)
runner_exit=0
env -u GATE_RUNNER_SCCACHE PATH="$uncached_path" bash "$script_dir/pr-gate-runner.sh" \
  >"$fixture/runner.log" 2>&1 || runner_exit=$?
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 1))"
grep -q 'sccache not found on PATH; acme/fixture builds uncached' "$fixture/runner.log" \
  || { printf 'a missing sccache was not reported\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
jq -se 'last.state=="success"' "$fixture/statuses.jsonl" >/dev/null
jq -e '.cache=="none"' "$fixture/runner/attempts/acme-fixture-$(cat "$fixture/head")/last-result.json" >/dev/null \
  || { printf 'the receipt did not record an uncached build\n' >&2; exit 1; }
printf 'no sccache, configured off\n' >>"$fixture/source/marker"
"$real_git" -C "$fixture/source" add marker
"$real_git" -C "$fixture/source" commit -qm sccache-off
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 2))"
! grep -q 'sccache not found on PATH' "$fixture/runner.log" \
  || { printf 'caching turned off was reported as a missing tool\n' >&2; exit 1; }
jq -e '.cache=="none"' "$fixture/runner/attempts/acme-fixture-$(cat "$fixture/head")/last-result.json" >/dev/null
printf 'PASS sccache absence is logged per gate and carried in the receipt, and never fails the gate\n'

# Heartbeats say what code the runner is: installed-main.json, as pr-gate-install.sh writes it. A
# forge that predates the field answers 422, and the runner sends the same heartbeat without it.
beats="$fixture/heartbeats.jsonl"
rm -f "$fixture/runner/installed-main.json"; : >"$beats"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
jq -se 'length>=1 and all(.[]; has("code")|not) and .[0].labels==["pr-gate"]' "$beats" >/dev/null \
  || { printf 'a runner with no installed-main.json sent code\n' >&2; cat "$beats" >&2; exit 1; }
installed_commit=89abcdef0123456789abcdef0123456789abcdef
jq -nc --arg c "$installed_commit" '{commit:$c,previous:"0000000",installed_at:"2026-10-01T01:02:03Z",files:[]}' \
  >"$fixture/runner/installed-main.json"
: >"$beats"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
jq -se --arg c "$installed_commit" 'length>=1 and all(.[]; .code=={repo:"example/gate-code",commit:$c,installedAt:"2026-10-01T01:02:03Z"})' \
  "$beats" >/dev/null || { printf 'the installed commit was not reported\n' >&2; cat "$beats" >&2; exit 1; }
touch "$fixture/reject-heartbeat-code"; : >"$beats"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
jq -se --arg c "$installed_commit" 'length>=2 and .[0].code.commit==$c and all(.[1:][]; has("code")|not)
  and (.[0]|del(.code))==.[1]' "$beats" >/dev/null \
  || { printf 'a 422 for code was not retried without it\n' >&2; cat "$beats" "$fixture/runner.log" >&2; exit 1; }
[[ "$(grep -c 'heartbeat code refused (422); retrying without it' "$fixture/runner.log")" == 1 ]]
if grep -q 'heartbeat refused' "$fixture/runner.log"; then cat "$fixture/runner.log" >&2; exit 1; fi
rm -f "$fixture/reject-heartbeat-code"
printf 'PASS heartbeats carry the installed code when known, none without it, and retry a 422 without it\n'

# ... and what it evaluates with: tools.json, as pr-gate-install.sh writes it, with invalid entries
# dropped. A 422 is retried without tools (keeping code), and if still refused, without code too.
jq -nc --arg s "$(printf 'c%.0s' {1..64})" '{generated_at:"2026-10-01T01:02:03Z",tools:[
  {name:"jankurai",version:"1.6.11",sha256:$s},{name:"jankurai@governed",version:"1.6.10"},{name:"Not Valid"}]}' \
  >"$fixture/runner/tools.json"
: >"$beats"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
jq -se --arg c "$installed_commit" --arg s "$(printf 'c%.0s' {1..64})" 'length>=1 and all(.[]; .code.commit==$c
  and .tools==[{name:"jankurai",version:"1.6.11",sha256:$s},{name:"jankurai@governed",version:"1.6.10"}])' "$beats" >/dev/null \
  || { printf 'the tools were not reported\n' >&2; cat "$beats" >&2; exit 1; }
touch "$fixture/reject-heartbeat-tools"; : >"$beats"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
jq -se --arg c "$installed_commit" 'length>=2 and (.[0]|has("tools")) and all(.[1:][]; (has("tools")|not) and .code.commit==$c)
  and (.[0]|del(.tools))==.[1]' "$beats" >/dev/null \
  || { printf 'a 422 for tools was not retried without them\n' >&2; cat "$beats" "$fixture/runner.log" >&2; exit 1; }
[[ "$(grep -c 'heartbeat tools refused (422); retrying without them' "$fixture/runner.log")" == 1 ]]
! grep -q 'heartbeat code refused\|heartbeat refused' "$fixture/runner.log" || { cat "$fixture/runner.log" >&2; exit 1; }
touch "$fixture/reject-heartbeat-code"; : >"$beats"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
jq -se 'length>=3 and (.[0]|has("tools") and has("code")) and (.[1]|(has("tools")|not) and has("code"))
  and all(.[2:][]; has("tools") or has("code") | not) and (.[0]|del(.tools,.code))==.[2]' "$beats" >/dev/null \
  || { printf 'a 422 for tools and code was not retried without both\n' >&2; cat "$beats" "$fixture/runner.log" >&2; exit 1; }
[[ "$(grep -c 'heartbeat tools refused (422); retrying without them' "$fixture/runner.log")" == 1 ]]
[[ "$(grep -c 'heartbeat code refused (422); retrying without it' "$fixture/runner.log")" == 1 ]]
! grep -q 'heartbeat refused' "$fixture/runner.log" || { cat "$fixture/runner.log" >&2; exit 1; }
rm -f "$fixture/reject-heartbeat-tools" "$fixture/reject-heartbeat-code" "$fixture/runner/tools.json"
printf 'PASS heartbeats carry the valid tools; a 422 is retried without tools, then without code, each logged once\n'

# Discovery reads each owner's checkout root from the site configuration: an explicit
# PR_GATE_CHECKOUT_ROOTS entry, else PR_GATE_CHECKOUT_ROOT_PATTERN with {owner} replaced, and keeps
# the checkouts whose origin is that owner's repository on the forge and whose main requires the context.
mkdir -p "$fixture/roots/acme"
"$real_git" clone -q --no-local "$fixture/source.git" "$fixture/roots/acme/fixture"
"$real_git" -C "$fixture/roots/acme/fixture" remote set-url origin https://forge.invalid/git/acme/fixture.git
"$real_git" clone -q --no-local "$fixture/source.git" "$fixture/roots/acme/foreign"
"$real_git" -C "$fixture/roots/acme/foreign" remote set-url origin https://elsewhere.invalid/git/acme/foreign.git
rm -f "$fixture/runner/cache/protected-acme"
listed=$(env -u GATE_RUNNER_REPOS -u GATE_RUNNER_FAMILY GATE_RUNNER_OWNERS=acme \
  PR_GATE_CHECKOUT_ROOT_PATTERN="$fixture/roots/{owner}" bash "$script_dir/pr-gate-runner.sh" --list 2>&1) || {
  printf 'discovery through the checkout-root pattern failed:\n%s\n' "$listed" >&2; exit 1; }
[[ "$listed" == "acme fixture 1 $(cat "$fixture/head") -" ]] || { printf 'pattern discovery listed:\n%s\n' "$listed" >&2; exit 1; }
[[ "$(cat "$fixture/runner/cache/protected-acme")" == acme/fixture ]]
rm -f "$fixture/runner/cache/protected-acme"
listed=$(env -u GATE_RUNNER_REPOS -u GATE_RUNNER_FAMILY GATE_RUNNER_OWNERS=acme \
  PR_GATE_CHECKOUT_ROOTS="other=/nonexistent acme=$fixture/roots/acme" PR_GATE_CHECKOUT_ROOT_PATTERN="/nonexistent/{owner}" \
  bash "$script_dir/pr-gate-runner.sh" --list 2>&1)
[[ "$listed" == "acme fixture 1 $(cat "$fixture/head") -" ]] || { printf 'explicit root discovery listed:\n%s\n' "$listed" >&2; exit 1; }
rm -f "$fixture/runner/cache/protected-acme"
listed=$(env -u GATE_RUNNER_REPOS -u GATE_RUNNER_FAMILY GATE_RUNNER_OWNERS=acme bash "$script_dir/pr-gate-runner.sh" --list 2>&1)
grep -q 'no checkout root for owner acme' <<<"$listed" || { printf 'a missing checkout root was silent:\n%s\n' "$listed" >&2; exit 1; }
grep -q 'no PR head needs gating' <<<"$listed"
printf 'PASS discovery: checkout roots come from the site configuration, and a missing one is named\n'

# A host whose site configuration lacks a required setting refuses to run, naming the setting.
for missing in PR_GATE_FORGE_URL JERYU_TOKEN_FILE GATE_RUNNER_IDENTITY; do
  grep -v "^$missing=" "$fixture/pr-gate.env" >"$fixture/partial.env"
  runner_exit=0
  env -u JERYU_TOKEN_FILE PR_GATE_CONFIG="$fixture/partial.env" bash "$script_dir/pr-gate-runner.sh" --list \
    >"$fixture/runner.log" 2>&1 || runner_exit=$?
  if [[ "$runner_exit" != 2 ]] || ! grep -q "$missing is not configured" "$fixture/runner.log"; then
    printf 'missing %s was not refused by name (exit %s)\n' "$missing" "$runner_exit" >&2; cat "$fixture/runner.log" >&2; exit 1
  fi
done
# A bare repository name needs a primary owner to qualify it.
grep -v '^PR_GATE_PRIMARY_OWNER=' "$fixture/pr-gate.env" >"$fixture/partial.env"
runner_exit=0
PR_GATE_CONFIG="$fixture/partial.env" GATE_RUNNER_REPOS=fixture bash "$script_dir/pr-gate-runner.sh" --list \
  >"$fixture/runner.log" 2>&1 || runner_exit=$?
if [[ "$runner_exit" == 0 ]] || ! grep -q 'has no owner and PR_GATE_PRIMARY_OWNER is not configured' "$fixture/runner.log"; then
  printf 'a bare repository name was guessed an owner\n' >&2; cat "$fixture/runner.log" >&2; exit 1
fi
printf 'PASS an unconfigured forge, credential, identity or primary owner is refused by name\n'
