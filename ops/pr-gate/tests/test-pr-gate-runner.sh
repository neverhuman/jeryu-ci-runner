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
# The recipe is synthetic and never compiles Rust. Give the child runner its own home and
# small toolchain, so each real input fingerprint binds these fixtures instead of repeatedly
# hashing the developer's installed compilers and user tools. Keep the production fingerprint
# code intact: mutations below must still invalidate receipts. test-pr-gate-state.sh also
# exercises the real host/toolchain enumeration and its failure paths.
mkdir -p "$fixture/home/.local/bin" "$fixture/home/.cargo" "$fixture/home/.rustup" "$fixture/toolchain/bin"
runner_env=(env HOME="$fixture/home" CARGO_HOME="$fixture/home/.cargo" RUSTUP_HOME="$fixture/home/.rustup")
printf '#!/bin/sh\nexit 0\n' >"$fixture/home/.local/bin/fixture-helper"
chmod +x "$fixture/home/.local/bin/fixture-helper"
for tool in rustc cargo; do
  printf '#!/usr/bin/env bash\n[[ "$*" == --version ]] || exit 64\nprintf "%%s\\n" "%s fixture-1"\n' "$tool" \
    >"$fixture/toolchain/bin/$tool"
done
cat >"$fixture/tools/rustup" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'which rustc'|'which cargo') printf '%s/toolchain/bin/%s\n' "$FAKE_FORGE" "$2";;
  'component list --toolchain toolchain --installed') printf 'rustc-fixture\ncargo-fixture\n';;
  *) printf 'unexpected fixture rustup invocation: %s\n' "$*" >&2; exit 64;;
esac
SH
chmod +x "$fixture/toolchain/bin/"*
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
# A second gate host (runner-b) keeps its mirrors in its own state directory.
[[ "$("$worker_git" remote get-url cache-mirror)" == "$expected_mirror" \
   || "$("$worker_git" remote get-url cache-mirror)" == "${expected_mirror/\/runner\//\/runner-b\/}" ]] \
  || { printf 'worker cache mirror is not separately named\n' >&2; exit 33; }
mkdir -p target
if [[ -n "${JERYU_CI_BUILD_CACHE_DIR:-}" ]]; then
  # Absolute, and exactly this checkout's cache: a cargo step run from a subdirectory must not grow a
  # nested target/ of its own.
  [[ "$JERYU_CI_BUILD_CACHE_DIR" == "$PWD/target/build-cache" && -d target/build-cache && ! -L target/build-cache ]] || exit 35
  # What the shared store seeded is visible before the recipe writes anything of its own.
  [[ ! -f "$fixture_root/expect-seeded" || -f "$JERYU_CI_BUILD_CACHE_DIR/seeded-marker" ]] || exit 37
  [[ ! -f "$fixture_root/expect-cold" || ! -e "$JERYU_CI_BUILD_CACHE_DIR/seeded-marker" ]] || exit 38
  printf 'ordinary build artifact\n' >"$JERYU_CI_BUILD_CACHE_DIR/artifact"
  [[ ! -f "$fixture_root/fail-build-cache" ]] || exit 36
fi
# The counter lives beside the fake forge, not in target/: a repository that does not share the build
# directory has target/ rebuilt from scratch for every gate, which would erase it.
count=0
[[ ! -f "$fixture_root/executions" ]] || read -r count <"$fixture_root/executions"
printf '%s\n' "$((count + 1))" >"$fixture_root/executions"
if [[ -f "$fixture_root/require-sibling" ]]; then
  cat ../sibling/file >/dev/null || exit 34
fi
# What the recipe was told to prove against, and what that ref is in its tree.
if [[ -n "${ACME_PROOF_BASE_REF+set}" ]]; then
  printf '%s %s\n' "$ACME_PROOF_BASE_REF" "$("$worker_git" rev-parse --verify --quiet "$ACME_PROOF_BASE_REF^{commit}" || printf missing)" \
    >>"$fixture_root/proof-base.log"
else
  printf 'unset\n' >>"$fixture_root/proof-base.log"
fi
if [[ -f "$fixture_root/mutate-tool" ]]; then
  printf 'changed during recipe\n' >>"$fixture_root/tools/environment-probe"
fi
printf 'error: expected rejection in a passing negative test\n'
# Step lines, one of them the gate's own credential: what a head's recipe may print, never publish.
printf '[pr-ci] fixture recipe step\n==> %s\n' "$(cat "$fixture_root/token")"
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
if [[ -f "$FAKE_FORGE/rate-limit" && "$method" == GET ]]; then
  printf '%s\n' "$url" >>"$FAKE_FORGE/rate-limited.log"
  printf '{"message":"rate limited"}\n429'; exit
fi
case "$method $url" in
  'GET '*'/pulls?state=open')
    # A second open pull request while $FAKE_FORGE/head2 names its head, for the order the tick gates in.
    if [[ -f "$FAKE_FORGE/head2" ]]; then
      jq -nc --arg sha "$head" --arg sha2 "$(cat "$FAKE_FORGE/head2")" \
        '{items:[{number:1,head_sha:$sha},{number:2,head_sha:$sha2}]}'
    else
      jq -nc --arg sha "$head" '{items:[{number:1,head_sha:$sha}]}'
    fi
    printf '\n200';;
  'GET '*'/pulls/2')
    jq -nc --arg sha "$(cat "$FAKE_FORGE/head2")" \
      '{state:"open",user:{login:"author"},head:{sha:$sha,ref:"author/second"},base:{ref:"main"},
        html_url:"https://forge.invalid/repos/jeryu/acme/fixture/pulls/2",
        created_at:"2026-10-09T18:26:18Z",updated_at:"2026-10-09T18:26:18Z"}'
    printf '\n200';;
  'GET '*'/pulls/1')
    count=0
    [[ ! -f "$FAKE_FORGE/head-reads" ]] || read -r count <"$FAKE_FORGE/head-reads"
    count=$((count + 1)); printf '%s\n' "$count" >"$FAKE_FORGE/head-reads"
    if [[ -f "$FAKE_FORGE/change-head" && "$count" -gt 1 ]]; then head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; fi
    # When the pull request was opened and last changed, as the forge dates them: what the runner
    # measures its queue wait from when nothing woke it for this head.
    opened=2026-10-09T18:26:18Z
    [[ ! -f "$FAKE_FORGE/pr-opened" ]] || read -r opened <"$FAKE_FORGE/pr-opened"
    jq -nc --arg sha "$head" --arg opened "$opened" --arg base "$(cat "$FAKE_FORGE/pr-base-ref" 2>/dev/null || echo main)" \
      '{state:"open",user:{login:"author"},head:{sha:$sha,ref:"author/feature"},base:{ref:$base},created_at:$opened,updated_at:$opened,
        html_url:"https://forge.invalid/repos/jeryu/acme/fixture/pulls/1"}'
    printf '\n200';;
  'GET '*'/refs')
    # The forge's ref listing with each branch's protection: refs.json, refs-fail (a transient 503),
    # or no file at all (a forge without the route).
    if [[ -f "$FAKE_FORGE/refs-fail" ]]; then printf '{"message":"upstream unavailable"}\n503'; exit; fi
    if [[ -f "$FAKE_FORGE/refs-429" ]]; then printf '{"message":"rate limited"}\n429'; exit; fi
    [[ -f "$FAKE_FORGE/refs.json" ]] || { printf '{"message":"not found"}\n404'; exit; }
    cat "$FAKE_FORGE/refs.json"; printf '\n200';;
  'GET '*'/api/v3/repos/acme/fixture')
    jq -nc '{name:"fixture",default_branch:"main"}'; printf '\n200';;
  'GET '*'/branches/main/protection')
    jq -nc '{required_status_checks:{contexts:["fixture/required"]}}'
    printf '\n200';;
  'GET '*'/branches/main')
    jq -nc --arg sha "$head" '{name:"main",commit:{sha:$sha}}'
    printf '\n200';;
  'GET '*'/gate-regate'*)
    if [[ -f "$FAKE_FORGE/refuse-regate" ]]; then printf '{"message":"re-gate list denied"}\n403'; exit; fi
    if [[ -f "$FAKE_FORGE/regate.json" ]]; then cat "$FAKE_FORGE/regate.json"; else printf '{"requests":[]}'; fi
    printf '\n200';;
  'GET '*'/merge-queue?state=building')
    # queue-arrives.json: empty for a tick's first read, then the entry -- one that arrives mid-tick.
    if [[ -f "$FAKE_FORGE/queue-arrives.json" ]]; then
      reads=0
      [[ ! -f "$FAKE_FORGE/queue-reads" ]] || read -r reads <"$FAKE_FORGE/queue-reads"
      printf '%s\n' "$((reads + 1))" >"$FAKE_FORGE/queue-reads"
      if ((reads == 0)); then printf '{"entries":[]}'; else cat "$FAKE_FORGE/queue-arrives.json"; fi
    elif [[ -f "$FAKE_FORGE/queue.json" ]]; then cat "$FAKE_FORGE/queue.json"; else printf '{"entries":[]}'; fi
    printf '\n200';;
  'GET '*'/status')
    # Statuses are per commit, as on the forge; a hand-written row without a sha applies to any.
    commit=${url%/status}; commit=${commit##*/}
    if [[ -f "$FAKE_FORGE/statuses.jsonl" ]]; then
      jq -sc --arg c "$commit" '{statuses:[.[] | select(.sha == null or .sha == $c)]}' "$FAKE_FORGE/statuses.jsonl"
    else printf '{"statuses":[]}'; fi
    printf '\n200';;
  'POST '*'/statuses/'*)
    # A forge that predates the status link refuses the field.
    if [[ -f "$FAKE_FORGE/reject-target-url" ]] && jq -e 'has("target_url")' <<<"$payload" >/dev/null; then
      printf 'Failed to deserialize the JSON body: unknown field `target_url`\n422'; exit
    fi
    if [[ -f "$FAKE_FORGE/reject-terminal" && "$(jq -r '.state' <<<"$payload")" != pending ]]; then
      printf '{"message":"publication denied"}\n403'; exit
    fi
    # forge-5xx holds how many more status posts answer 503 before the forge recovers (-1: never).
    if [[ -f "$FAKE_FORGE/forge-5xx" ]]; then
      read -r left <"$FAKE_FORGE/forge-5xx"
      printf '%s\n' "$url $(jq -r '.state' <<<"$payload")" >>"$FAKE_FORGE/forge-5xx.log"
      if ((left != 0)) && [[ "$(jq -r '.state' <<<"$payload")" != error || "$left" == -1 ]]; then
        ((left < 0)) || printf '%s\n' "$((left - 1))" >"$FAKE_FORGE/forge-5xx"
        printf '{"message":"upstream unavailable"}\n503'; exit
      fi
    fi
    count=0
    [[ ! -f "$FAKE_FORGE/statuses.jsonl" ]] || count=$(wc -l <"$FAKE_FORGE/statuses.jsonl")
    # The forge records the token's identity as the creator, as jeryu does (commit_status creator).
    result=$(jq -c --arg id "status-$count" --argjson clock "$count" --arg sha "${url##*/statuses/}" \
      '. + {id:$id,updated_at:$clock,sha:$sha,creator:{login:"runner-bot"}}' <<<"$payload")
    printf '%s\n' "$result" >>"$FAKE_FORGE/statuses.jsonl"
    printf '%s\n201' "$result";;
  'POST '*'/check-runs')
    if [[ -f "$FAKE_FORGE/reject-check-run" ]]; then printf '{"message":"check runs unavailable"}\n500'; exit; fi
    printf '%s\n' "$payload" >>"$FAKE_FORGE/check-runs.jsonl"
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
export PATH="$fixture/tools:$fixture/toolchain/bin:/usr/bin:/bin"
invoke() {
  runner_exit=0
  "${runner_env[@]}" bash "$script_dir/pr-gate-runner.sh" "$@" >"$fixture/runner.log" 2>&1 || runner_exit=$?
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
jq -e --arg root "$fixture/toolchain/bin" '.toolchain_paths == [$root + "/rustc", $root + "/cargo"]' \
  "$fixture/runner/attempts/acme-fixture-$(cat "$fixture/head")/last-result.json" >/dev/null \
  || { printf 'the runner did not bind the fixture toolchain\n' >&2; exit 1; }
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count 1
printf 'PASS complete runner: negative-test log is success; identical receipt reuses\n'

# A second gate host: its own state directory (no receipts at all), its tools installed somewhere else,
# its own credential path, and a site file with other comments and order. Same runner code, tools,
# sources and verdict-changing settings, so it computes the same inputs and adopts the first host's
# success from the forge -- as a deferral: with nothing else to run, the same tick re-proves the head
# here (without posting `pending` over the first host's green), so a wrong forge status cannot stand.
cp -R "$fixture/tools" "$fixture/tools-b"
cp -p "$fixture/token" "$fixture/token-b"
{ printf '# the second host\n'; grep -v '^JERYU_TOKEN_FILE=' "$fixture/pr-gate.env" | tac
  printf 'JERYU_TOKEN_FILE=%s\n' "$fixture/token-b"; } >"$fixture/pr-gate-b.env"
published=$(wc -l <"$fixture/statuses.jsonl")
PR_GATE_CONFIG="$fixture/pr-gate-b.env" GATE_RUNNER_HOME="$fixture/runner-b" GATE_RUNNER_TOOLS="$fixture/tools-b" invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
grep -q 'reuse acme/fixture@.*from the forge result' "$fixture/runner.log" || { cat "$fixture/runner.log"; exit 1; }
grep -q 'idle: re-proving acme/fixture#1' "$fixture/runner.log" || { cat "$fixture/runner.log"; exit 1; }
expect_count 2
jq -se --argjson n "$published" '.[$n:] | length == 1 and (.[0].state == "success")
  and (.[0].description | test("; inputs [0-9a-f]{64}$"))' "$fixture/statuses.jsonl" >/dev/null \
  || { printf 'the second host should post exactly its own success, and no pending\n' >&2; tail -3 "$fixture/statuses.jsonl" >&2; exit 1; }
# Back on the first host: the newer success is another host's for exactly these inputs, and its own
# verified receipt still stands, so it neither re-runs nor adopts (no bouncing between hosts).
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count 2
grep -qE 'reuse acme/fixture@.*(from the local result|read without preparing a tree)' "$fixture/runner.log" || { cat "$fixture/runner.log"; exit 1; }
! grep -q 'idle: re-proving' "$fixture/runner.log" || { cat "$fixture/runner.log"; exit 1; }
printf '1\n' >"$fixture/executions"   # the counts below are the first host's own
printf 'PASS a second host adopts the forge result, re-proves it when idle, and the first host keeps its own\n'

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

# A head that changes the gate it is judged by is said so on the check run and recorded on the
# attempt: the recipe that just passed is the head's own. The conclusion is unchanged, and the
# recipe is still the head's -- running it from protected main is deliberately not done here.
rm -f "$fixture/check-runs.jsonl"
"$real_git" -C "$fixture/source" checkout -q -b self-gate
mkdir -p "$fixture/source/ops/ci"
printf 'ops/ci/pr-ci.sh\n' >"$fixture/source/ops/ci/pr-ci.sh"
mkdir -p "$fixture/source/docs"
# Documentation about the gate is not the gate: it must not be named.
printf 'how the gate works\n' >"$fixture/source/docs/jankurai-gate.md"
"$real_git" -C "$fixture/source" add ops/ci/pr-ci.sh docs/jankurai-gate.md
"$real_git" -C "$fixture/source" commit -qm "rewrite the gate"
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" HEAD:refs/heads/self-gate
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
head=$(cat "$fixture/head")
jq -se 'last.state=="success"' "$fixture/statuses.jsonl" >/dev/null
jq -e '.gate_definition_paths == ["ops/ci/pr-ci.sh"]' \
  "$fixture/runner/attempts/acme-fixture-$head/last-result.json" >/dev/null \
  || { printf 'the attempt did not record the gate-defining paths\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
jq -se 'last.output.text | test("^Needs a human: this head changes the gate that judges it \\(ops/ci/pr-ci\\.sh\\)")' \
  "$fixture/check-runs.jsonl" >/dev/null \
  || { printf 'the check run was not annotated\n' >&2; cat "$fixture/check-runs.jsonl" >&2; exit 1; }
jq -se 'last.output.summary | test("changes its own gate$")' "$fixture/check-runs.jsonl" >/dev/null
# The required status is the gate and says only what the gate concluded.
jq -se 'last.description | test("changes its own gate")|not' "$fixture/statuses.jsonl" >/dev/null
grep -q 'acme/fixture#1 changes its own gate: ops/ci/pr-ci.sh' "$fixture/runner.log" \
  || { cat "$fixture/runner.log" >&2; exit 1; }
"$real_git" -C "$fixture/source" checkout -q main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
rm -f "$fixture/check-runs.jsonl"
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
jq -se 'last.output | has("text") | not' "$fixture/check-runs.jsonl" >/dev/null \
  || { printf 'a head equal to main was flagged as changing its gate\n' >&2; cat "$fixture/check-runs.jsonl" >&2; exit 1; }
printf 'PASS complete runner: a head that changes its own gate is flagged, an ordinary head is not\n'

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
grep -q 'fresh outputs in its own tree' "$fixture/runner.log"
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
# for step 5 to check out.
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

# That result was computed with GATE_RUNNER_SHARED_TARGETS set in the environment (as a unit's
# Environment= line would): the effective setting is an input, so with it gone the head is re-gated
# once, and then reused.
before_count=$(count)
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 1))"
invoke
expect_count "$((before_count + 1))"
printf 'PASS complete runner: an environment override is part of the inputs, not only the site file\n'

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
      and .[0].state=="pending" and .[1].state=="success" and all(has("target_url") | not)' >/dev/null \
  || { printf 'queue statuses were not pending then success on the queue sha (with no PR checks link)\n' >&2; cat "$fixture/statuses.jsonl" >&2; exit 1; }
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

# An entry that arrives while a tick is deciding PR heads ends that tick before the next head, so the
# next tick gates it first instead of after a slot frees elsewhere.
printf 'new head while the queue is empty\n' >>"$fixture/source/marker"
"$real_git" -C "$fixture/source" add marker
"$real_git" -C "$fixture/source" commit -qm head-before-queue
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
"$real_git" -C "$fixture/source" checkout -q -B queue-build-2 main
printf 'replayed mid-tick\n' >"$fixture/source/queued"
"$real_git" -C "$fixture/source" add queued
"$real_git" -C "$fixture/source" commit -qm queue-replay-2
qsha2=$("$real_git" -C "$fixture/source" rev-parse HEAD)
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" "+HEAD:refs/queue/main/1"
"$real_git" -C "$fixture/source" checkout -q main
queue_entry "$qsha2" refs/queue/main/1
mv "$fixture/queue.json" "$fixture/queue-arrives.json"
rm -f "$fixture/queue-reads"
before_count=$(count)
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$before_count"
grep -q "merge-queue entry acme/fixture at $qsha2 arrived during this tick" "$fixture/runner.log" \
  || { printf 'a mid-tick queue entry did not end the tick\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
! grep -q "preparing acme/fixture#1 at $(cat "$fixture/head")" "$fixture/runner.log" \
  || { printf 'the PR head was prepared ahead of a waiting queue entry\n' >&2; exit 1; }
mv "$fixture/queue-arrives.json" "$fixture/queue.json"
invoke
expect_count "$((before_count + 1))"
grep -q "preparing acme/fixture#1 at $qsha2 (merge queue refs/queue/main/1)" "$fixture/runner.log" \
  || { printf 'the next tick did not gate the arrived entry first\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
# Seen at the start of a tick and already claimed, the same entry never ends a tick again.
invoke
expect_count "$((before_count + 2))"
! grep -q 'arrived during this tick' "$fixture/runner.log" \
  || { printf 'a claimed entry ended a tick\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
rm -f "$fixture/queue.json" "$fixture/queue-reads"
printf 'PASS merge queue: an entry arriving mid-tick ends the tick and is gated first by the next\n'

# A sibling's main moving re-gates open heads automatically, but a burst is coalesced: the runner
# records the family's mains after each mirror fetch, and while they moved within the settle window an
# already-gated head waits. An explicit --repo/--pr is never deferred.
printf 'main moved\n' >"$fixture/source/moved"
"$real_git" -C "$fixture/source" add moved
"$real_git" -C "$fixture/source" commit -qm main-moves
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" HEAD:refs/heads/main
moved_main=$("$real_git" -C "$fixture/source" rev-parse HEAD)
mains="$fixture/runner/cache/mains/acme/fixture"
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
# Settled, so the head is decided on its inputs again instead of waiting. This fixture's family is
# the gated repository itself, so its own main moving past the head changes none of that head's
# inputs and the decision is reuse; a sibling's main really moving is exercised below.
grep -q 'reuse acme/fixture@' "$fixture/runner.log" \
  || { printf 'a settled head was not decided again\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
printf 'PASS re-gate on a moved main: a burst is coalesced, explicit retry is not deferred, a settled head is decided again\n'

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
listed=$(GATE_RUNNER_REGATE_SETTLE=3600 "${runner_env[@]}" bash "$script_dir/pr-gate-runner.sh" --list 2>&1)
grep -q "^acme fixture 1 $head - 0 " <<<"$listed" \
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
env -u GATE_RUNNER_SCCACHE PATH="$uncached_path" "${runner_env[@]}" bash "$script_dir/pr-gate-runner.sh" \
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

# Main-health gates the protected main commit under its own context. A green main SHA is skipped on
# the next scheduled pass, but an explicit repo pass runs on demand.
before_count=$(count)
before_statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke --main-health
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 1))"
tail -n +"$((before_statuses + 1))" "$fixture/statuses.jsonl" \
  | jq -se 'length>=1 and last.context=="fixture/main-health" and last.state=="success"' >/dev/null \
  || { printf 'main-health did not publish success on its own context\n' >&2; cat "$fixture/statuses.jsonl" >&2; exit 1; }
invoke --main-health
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 1))"
grep -q 'skip acme/fixture main-health' "$fixture/runner.log" \
  || { printf 'an unchanged green main-health run was not skipped\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
invoke --main-health --repo acme/fixture
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 2))"
guard="$fixture/release.guard"; : >"$guard"
GATE_RUNNER_RELEASE_GUARD_FILE="$guard" invoke --main-health
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 2))"
grep -q 'release guard is present; skipping main-health' "$fixture/runner.log"
rm -f "$guard"
printf 'PASS main-health: posts a distinct context, skips unchanged green main, runs on demand and respects the release guard\n'

# A main-health pass takes the repository pr-gate-wake.sh woke it for from its own hint file, so a
# pass woken by a push to one repository cannot spend the pull-request slots' hint instead.
printf 'acme/fixture 1 %s pr-head -\n' "$(cat "$fixture/head" 2>/dev/null || printf -- -)" \
  >"$fixture/runner/cache/wake-dispatch"
printf 'acme/fixture - - push %s\n' "$(date -u -d '-30 seconds' +%FT%TZ)" \
  >"$fixture/runner/cache/wake-main-dispatch"
invoke --main-health
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
grep -q 'woken for acme/fixture (push)' "$fixture/runner.log" \
  || { printf 'the main-health pass did not take its own wake-up\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
[[ ! -s "$fixture/runner/cache/wake-main-dispatch" ]] \
  || { printf 'the main-health wake-up line was not taken\n' >&2; exit 1; }
[[ -s "$fixture/runner/cache/wake-dispatch" ]] \
  || { printf 'the main-health pass took a pull-request hint\n' >&2; exit 1; }
: >"$fixture/runner/cache/wake-dispatch"
printf 'PASS a main-health pass reads its own wake-up hints and leaves the pull-request ones alone\n'

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
  PR_GATE_CHECKOUT_ROOT_PATTERN="$fixture/roots/{owner}" "${runner_env[@]}" bash "$script_dir/pr-gate-runner.sh" --list 2>&1) || {
  printf 'discovery through the checkout-root pattern failed:\n%s\n' "$listed" >&2; exit 1; }
[[ "$listed" == "acme fixture 1 $(cat "$fixture/head") - 0 main 2026-10-09T18:26:18Z|pr-opened" ]] || { printf 'pattern discovery listed:\n%s\n' "$listed" >&2; exit 1; }
[[ "$(cat "$fixture/runner/cache/protected-acme")" == acme/fixture ]]
rm -f "$fixture/runner/cache/protected-acme"
listed=$(env -u GATE_RUNNER_REPOS -u GATE_RUNNER_FAMILY GATE_RUNNER_OWNERS=acme \
  PR_GATE_CHECKOUT_ROOTS="other=/nonexistent acme=$fixture/roots/acme" PR_GATE_CHECKOUT_ROOT_PATTERN="/nonexistent/{owner}" \
  "${runner_env[@]}" bash "$script_dir/pr-gate-runner.sh" --list 2>&1)
[[ "$listed" == "acme fixture 1 $(cat "$fixture/head") - 0 main 2026-10-09T18:26:18Z|pr-opened" ]] || { printf 'explicit root discovery listed:\n%s\n' "$listed" >&2; exit 1; }
rm -f "$fixture/runner/cache/protected-acme"
listed=$(env -u GATE_RUNNER_REPOS -u GATE_RUNNER_FAMILY GATE_RUNNER_OWNERS=acme "${runner_env[@]}" bash "$script_dir/pr-gate-runner.sh" --list 2>&1)
grep -q 'no checkout root for owner acme' <<<"$listed" || { printf 'a missing checkout root was silent:\n%s\n' "$listed" >&2; exit 1; }
grep -q 'no PR head needs gating' <<<"$listed"
printf 'PASS discovery: checkout roots come from the site configuration, and a missing one is named\n'

# A host whose site configuration lacks a required setting refuses to run, naming the setting.
for missing in PR_GATE_FORGE_URL JERYU_TOKEN_FILE GATE_RUNNER_IDENTITY; do
  grep -v "^$missing=" "$fixture/pr-gate.env" >"$fixture/partial.env"
  runner_exit=0
  env -u JERYU_TOKEN_FILE PR_GATE_CONFIG="$fixture/partial.env" "${runner_env[@]}" bash "$script_dir/pr-gate-runner.sh" --list \
    >"$fixture/runner.log" 2>&1 || runner_exit=$?
  if [[ "$runner_exit" != 2 ]] || ! grep -q "$missing is not configured" "$fixture/runner.log"; then
    printf 'missing %s was not refused by name (exit %s)\n' "$missing" "$runner_exit" >&2; cat "$fixture/runner.log" >&2; exit 1
  fi
done
# A bare repository name needs a primary owner to qualify it.
grep -v '^PR_GATE_PRIMARY_OWNER=' "$fixture/pr-gate.env" >"$fixture/partial.env"
runner_exit=0
PR_GATE_CONFIG="$fixture/partial.env" GATE_RUNNER_REPOS=fixture "${runner_env[@]}" bash "$script_dir/pr-gate-runner.sh" --list \
  >"$fixture/runner.log" 2>&1 || runner_exit=$?
if [[ "$runner_exit" == 0 ]] || ! grep -q 'has no owner and PR_GATE_PRIMARY_OWNER is not configured' "$fixture/runner.log"; then
  printf 'a bare repository name was guessed an owner\n' >&2; cat "$fixture/runner.log" >&2; exit 1
fi
printf 'PASS an unconfigured forge, credential, identity or primary owner is refused by name\n'

# The head pr-gate-wake.sh woke this slot for, and the queue wait every gate records: from the
# moment the head became gateable to the moment its gate started. Without a wake-up the pull request
# dates itself; with one the forge's own time is used, and a line too old to be worth acting on is
# dropped unread.
rm -f "$fixture/runner/cache/protected-acme"
# A head of its own per gate: an identical head reuses its result instead of running again.
moved=0
new_head() {
  moved=$((moved + 1))
  printf 'pass\n' >"$fixture/source/mode"
  printf 'dispatch case %s\n' "$moved" >>"$fixture/source/marker"
  "$real_git" -C "$fixture/source" add mode marker
  "$real_git" -C "$fixture/source" commit -qm "move the head ($moved)"
  "$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
  "$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
  head=$(cat "$fixture/head")
  receipt="$fixture/runner/attempts/acme-fixture-$head/last-result.json"
}
dispatch="$fixture/runner/cache/wake-dispatch"

printf '%s\n' "$(date -u -d '-90 seconds' +%FT%TZ)" >"$fixture/pr-opened"
new_head
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
jq -e '.outcome == "success" and .exit_code == 0 and .queue_wait.source == "pr-opened" and .queue_wait.seconds >= 85 and .queue_wait.seconds <= 300' "$receipt" >/dev/null \
  || { printf 'the queue wait was not measured from the pull request\n' >&2; jq -c .queue_wait "$receipt" >&2; exit 1; }
grep -q 'queue wait .*pr-opened' "$fixture/runner.log" || { cat "$fixture/runner.log" >&2; exit 1; }
printf 'PASS a gate records how long its head waited, dated by the pull request itself\n'

new_head
woken_at=$(date -u -d '-30 seconds' +%FT%TZ)
printf 'acme/fixture 1 %s push %s\n' "$head" "$woken_at" >"$dispatch"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
grep -q "woken for acme/fixture#1 (push)" "$fixture/runner.log" || { cat "$fixture/runner.log" >&2; exit 1; }
[[ ! -s "$dispatch" ]] || { printf 'the wake-up line was not taken\n' >&2; cat "$dispatch" >&2; exit 1; }
jq -e --arg at "$woken_at" '.queue_wait.source == "push" and .queue_wait.ready_at == $at
  and .queue_wait.seconds >= 25 and .queue_wait.seconds <= 300' "$receipt" >/dev/null \
  || { printf 'the wake-up did not date the queue wait\n' >&2; jq -c .queue_wait "$receipt" >&2; exit 1; }
printf 'PASS a woken slot gates the head it was woken for and dates the wait from the forge\n'

# A line nobody took in time is dropped rather than acted on, a malformed one is read once, and a
# wake-up the forge gave no time for leaves the pull request to date the wait.
new_head
printf 'acme/fixture 1 %s push 2000-01-01T00:00:00Z\nnot a wake-up line\nacme/fixture - - pr-head -\n' "$head" >"$dispatch"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
for expected in 'dropping a stale wake-up for acme/fixture' \
                'ignoring a malformed wake-up line: not a wake-up line' \
                'woken for acme/fixture (pr-head)'; do
  grep -q "$expected" "$fixture/runner.log" || { printf 'missing: %s\n' "$expected" >&2; cat "$fixture/runner.log" >&2; exit 1; }
done
[[ ! -s "$dispatch" ]] || { printf 'lines stepped over were kept\n' >&2; cat "$dispatch" >&2; exit 1; }
jq -e '.queue_wait.source == "pr-opened"' "$receipt" >/dev/null \
  || { printf 'an undated wake-up overrode the pull request\n' >&2; jq -c .queue_wait "$receipt" >&2; exit 1; }
rm -f "$fixture/pr-opened"
printf 'PASS a stale or malformed wake-up line is dropped once, and an undated one defers to the pull request\n'

# Order: with two heads needing a gate, the tick takes the one it was woken for. That is what hands a
# new pull request to whichever slot is idle instead of letting it wait behind the slot's own pass.
new_head
"$real_git" -C "$fixture/source" checkout -q -b second
printf 'pass\n' >"$fixture/source/mode"
printf 'second dispatch head\n' >>"$fixture/source/marker"
"$real_git" -C "$fixture/source" add mode marker
"$real_git" -C "$fixture/source" commit -qm "a second open head"
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" second
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head2"
"$real_git" -C "$fixture/source" checkout -q main
printf 'acme/fixture 2 %s pr-head -\n' "$(cat "$fixture/head2")" >"$dispatch"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
grep -q 'preparing acme/fixture#2' "$fixture/runner.log" \
  || { printf 'the tick did not gate the head it was woken for\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
! grep -q 'preparing acme/fixture#1' "$fixture/runner.log" || { cat "$fixture/runner.log" >&2; exit 1; }
# And with no wake-up the order is the one it always was: the lowest-numbered head of the pass.
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
grep -q 'preparing acme/fixture#1' "$fixture/runner.log" \
  || { printf 'without a wake-up the tick did not take the first head of its pass\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
printf 'PASS a woken slot gates the head it was woken for before the rest of its pass\n'

# The link on the status and the check run names the PR actually gated, never the last one listed:
# with #1 and #2 open, a tick that gates #1 links #1's checks page.
new_head
rm -f "$fixture/check-runs.jsonl"
before_statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
grep -q 'preparing acme/fixture#1' "$fixture/runner.log" || { cat "$fixture/runner.log" >&2; exit 1; }
tail -n +"$((before_statuses + 1))" "$fixture/statuses.jsonl" | jq -se --arg s "$(cat "$fixture/head")" '
  length == 2 and all(.sha == $s and .target_url == "https://forge.invalid/repos/jeryu/acme/fixture/pulls/1/checks")' >/dev/null \
  || { printf 'the status did not link the gated PR\n' >&2; tail -2 "$fixture/statuses.jsonl" >&2; exit 1; }
jq -se 'last.details_url == "https://forge.invalid/repos/jeryu/acme/fixture/pulls/1/checks"' "$fixture/check-runs.jsonl" >/dev/null \
  || { printf 'the check run did not link the gated PR\n' >&2; cat "$fixture/check-runs.jsonl" >&2; exit 1; }
# The head printed the gate's credential as a step line: the attempt keeps it, the forge never sees it.
receipt="$fixture/runner/attempts/acme-fixture-$(cat "$fixture/head")/last-result.json"
grep -qF synthetic-fixture-token "$(dirname "$(jq -r '.log' "$receipt")")/steps.tsv" \
  || { printf 'the step was not recorded on the runner\n' >&2; exit 1; }
if grep -qF synthetic-fixture-token "$fixture/check-runs.jsonl" "$fixture/statuses.jsonl"; then
  printf 'a step line printed by the head reached the forge\n' >&2; exit 1
fi
jq -se 'last.output.summary | test("^✓ step 1 · [0-9]+s\n✓ step 2 · ")' "$fixture/check-runs.jsonl" >/dev/null \
  || { printf 'steps outside protected main were not published as numbers\n' >&2; cat "$fixture/check-runs.jsonl" >&2; exit 1; }
rm -f "$fixture/head2"
printf 'PASS the links name the gated PR; a head-printed step line never reaches the forge\n'

# A forge that refuses the link (422) still gets the gate's statuses, without it: the link never fails a gate.
new_head
touch "$fixture/reject-target-url"
before_statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
tail -n +"$((before_statuses + 1))" "$fixture/statuses.jsonl" | jq -se --arg s "$(cat "$fixture/head")" '
  length == 2 and all(.sha == $s and (has("target_url") | not)) and .[0].state == "pending" and .[1].state == "success"' >/dev/null \
  || { printf 'a refused link failed or changed the gate\n' >&2; cat "$fixture/runner.log" >&2; tail -2 "$fixture/statuses.jsonl" >&2; exit 1; }
grep -q 'status link refused (422)' "$fixture/runner.log" || { cat "$fixture/runner.log" >&2; exit 1; }
rm -f "$fixture/reject-target-url"
printf 'PASS a forge that refuses the status link gets the same statuses without it\n'
# A 429 on a read starts one back-off for every slot: the next tick makes no request at all, and
# the first answer that is not a 429 ends it.
rm -f "$fixture/runner/cache/forge-backoff" "$fixture/rate-limited.log"
touch "$fixture/rate-limit"
env -u GATE_RUNNER_FAMILY GATE_RUNNER_REPOS=fixture "${runner_env[@]}" bash "$script_dir/pr-gate-runner.sh" --list >"$fixture/runner.log" 2>&1 || true
[[ -s "$fixture/runner/cache/forge-backoff" ]] || { printf 'a 429 started no back-off\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
grep -q 'answered 429' "$fixture/runner.log"
sent=$(wc -l <"$fixture/rate-limited.log")
env -u GATE_RUNNER_FAMILY GATE_RUNNER_REPOS=fixture "${runner_env[@]}" bash "$script_dir/pr-gate-runner.sh" --list >"$fixture/runner.log" 2>&1 || true
[[ "$(wc -l <"$fixture/rate-limited.log")" == "$sent" ]] || { printf 'a request went out during the back-off\n' >&2; exit 1; }
grep -q 'rate limiting this identity' "$fixture/runner.log"
rm -f "$fixture/rate-limit" "$fixture/runner/cache/forge-backoff"
printf 'PASS a 429 backs every slot off: no request goes out until the back-off passes\n'

# Reuse is decided from the head's input identity before any tree is prepared: an unchanged head
# costs no mirror checkout, no reset and no tree-wide fingerprint, which is what ~40 open heads spent
# ~35 slot-hours a day on. The identity is the same one the receipt pins, so a sibling main that
# moved and a governed tool that was reinstalled still re-gate the head, and an explicit retry or a
# re-gate the forge asked for is never short-circuited.
git init -q --initial-branch=main "$fixture/sibling-src"
git -C "$fixture/sibling-src" config user.name Fixture
git -C "$fixture/sibling-src" config user.email fixture@example.invalid
printf 'first\n' >"$fixture/sibling-src/file"
git -C "$fixture/sibling-src" add file
git -C "$fixture/sibling-src" commit -qm sibling
git clone -q --bare --no-local "$fixture/sibling-src" "$fixture/sibling.git"
export GATE_RUNNER_FAMILY="fixture sibling"
printf 'with a sibling\n' >>"$fixture/source/marker"
"$real_git" -C "$fixture/source" add marker
"$real_git" -C "$fixture/source" commit -qm cheap-identity-fixture
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
head=$(cat "$fixture/head")
before_count=$(count)
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 1))"
jq -e '[.inputs.sources[].repository] == ["fixture","sibling"]' \
  "$fixture/runner/attempts/acme-fixture-$head/last-result.json" >/dev/null \
  || { printf 'the sibling was not bound into the identity\n' >&2; exit 1; }
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 1))"
grep -q "reuse acme/fixture@$head: identical verified inputs, read without preparing a tree" "$fixture/runner.log" \
  || { printf 'an unchanged head was not reused before preparation\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
! grep -q 'preparing acme/fixture#1' "$fixture/runner.log" \
  || { printf 'an unchanged head still prepared a tree\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
printf 'PASS cheap identity: an unchanged head is reused without preparing a tree\n'

# A sibling main that moved is a changed input, read straight out of the refreshed mirror: the head is
# prepared and gated again. Exact-source authority -- trusting the receipt and the forge status alone --
# would have missed this.
printf 'moved\n' >"$fixture/sibling-src/file"
git -C "$fixture/sibling-src" add file
git -C "$fixture/sibling-src" commit -qm sibling-moves
git -C "$fixture/sibling-src" push -q "$fixture/sibling.git" main
sibling_main=$(git -C "$fixture/sibling-src" rev-parse HEAD)
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 2))"
grep -q 'preparing acme/fixture#1' "$fixture/runner.log" \
  || { printf 'a moved sibling main did not re-gate the head\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
jq -e --arg s "$sibling_main" 'any(.inputs.sources[]; .repository=="sibling" and .head==$s)' \
  "$fixture/runner/attempts/acme-fixture-$head/last-result.json" >/dev/null \
  || { printf 'the re-gate did not bind the moved sibling main\n' >&2; exit 1; }
invoke
expect_count "$((before_count + 2))"
# ... and so is a governed tool that was installed since: what the gate evaluates with is hashed on
# every tick, never read from the receipt.
printf 'a governed tool arrived\n' >"$fixture/tools/governed-marker"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 3))"
grep -q 'preparing acme/fixture#1' "$fixture/runner.log" \
  || { printf 'a reinstalled governed tool did not re-gate the head\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
printf 'PASS cheap identity: a moved sibling main and a reinstalled governed tool re-gate the head\n'

# An explicit retry and a re-gate the forge asked for are retries of this head, so neither is ever
# answered from a reusable receipt -- and an explicit retry still refreshes the head before it
# dispatches, so a head that moved under it runs nothing at all.
invoke
expect_count "$((before_count + 3))"
grep -q 'read without preparing a tree' "$fixture/runner.log"
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 4))"
! grep -q 'read without preparing a tree' "$fixture/runner.log" \
  || { printf 'an explicit retry was answered from the receipt\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
jq -nc --arg s "$head" '{requests:[{repo:"acme/fixture",number:1,head_sha:$s,
  requested_at:"2026-10-10T07:00:00Z",requested_by:"dana"}]}' >"$fixture/regate.json"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 5))"
! grep -q 'read without preparing a tree' "$fixture/runner.log" \
  || { printf 'a requested re-gate was answered from the receipt\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
grep -q "re-gate requested for acme/fixture#1 at $head" "$fixture/runner.log"
rm -f "$fixture/regate.json"
touch "$fixture/change-head"
rm -f "$fixture/head-reads"
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 5))"
grep -q 'head changed or PR closed' "$fixture/runner.log" \
  || { printf 'an explicit retry dispatched without refreshing the head\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
rm -f "$fixture/change-head"
printf 'PASS cheap identity: an explicit retry and a requested re-gate are never short-circuited\n'

# Deciding reuse this early takes no claim of its own: the head is already inside its claim lock, and
# flock is released by the kernel when a slot dies. Nothing is left behind for a killed slot to park
# the head on -- a claim directory would leave it "recovery required" for as long as it stayed open.
rm -rf "$fixture/runner/claims"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
grep -q 'read without preparing a tree' "$fixture/runner.log"
[[ -f "$fixture/runner/claim-locks/acme-fixture-$head.lock" ]] \
  || { printf 'the head was not serialised by its claim lock\n' >&2; exit 1; }
[[ -z "$(ls -A "$fixture/runner/claims" 2>/dev/null)" ]] \
  || { printf 'reuse before preparation left a claim behind: %s\n' "$(ls -A "$fixture/runner/claims")" >&2; exit 1; }
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
if grep -q 'recovery required' "$fixture/runner.log"; then
  printf 'reuse before preparation parked the head in recovery\n' >&2
  cat "$fixture/runner.log" >&2
  exit 1
fi
grep -q 'read without preparing a tree' "$fixture/runner.log"
rm -f "$fixture/tools/governed-marker"
export GATE_RUNNER_FAMILY=fixture
printf 'PASS cheap identity: reuse before preparation claims nothing and never parks the head in recovery\n'

# A declared closure binds the policy and real sibling inputs, and physically removes old checkouts.
# It must not just omit them from the digest while recipes can still read them.
export GATE_RUNNER_FAMILY="fixture sibling"
export PR_GATE_DEPENDENCIES='acme/fixture=sibling'
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
before_count=$(count)
printf 'declared dependency moved\n' >>"$fixture/sibling-src/file"
git -C "$fixture/sibling-src" commit -qam declared-dependency-moves
git -C "$fixture/sibling-src" push -q "$fixture/sibling.git" main
invoke
expect_count "$((before_count + 1))"
receipt="$fixture/runner/attempts/acme-fixture-$head/last-result.json"
jq -e '[.inputs.sources[].repository] == ["fixture","sibling"]' "$receipt" >/dev/null
export PR_GATE_DEPENDENCIES='acme/fixture=-'
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 2))"
[[ ! -e "$fixture/runner/tree/sibling" ]]
jq -e '[.inputs.sources[].repository] == ["fixture"]' "$receipt" >/dev/null
settled=$(stat -c %Y "$fixture/runner/cache/mains/acme/fixture")
printf 'unrelated sibling moved\n' >>"$fixture/sibling-src/file"
git -C "$fixture/sibling-src" commit -qam unrelated-sibling-moves
git -C "$fixture/sibling-src" push -q "$fixture/sibling.git" main
invoke
expect_count "$((before_count + 2))"
grep -q 'read without preparing a tree' "$fixture/runner.log"
[[ "$(stat -c %Y "$fixture/runner/cache/mains/acme/fixture")" == "$settled" ]]
touch "$fixture/require-sibling"
invoke --repo acme/fixture --pr 1
expect_count "$((before_count + 3))"
jq -e '.terminal and .exit_code == 34' "$receipt" >/dev/null
rm -f "$fixture/require-sibling"
export PR_GATE_DEPENDENCIES='acme/fixture=nomain'
invoke
# The head fails; the tick does not: a missing declared main must never wedge every slot.
[[ "$runner_exit" == 0 ]] || { printf 'a missing declared main ended the tick\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
grep -q 'acme/fixture cannot be gated' "$fixture/runner.log"
expect_count "$((before_count + 3))"
grep -q 'declared dependency acme/nomain has no canonical main' "$fixture/runner.log"
jq -se 'last.state == "failure" and (last.description | contains("declared dependency acme/nomain"))' "$fixture/statuses.jsonl" >/dev/null
# An unrelated map entry must not change the default family selection for this repository.
export PR_GATE_DEPENDENCIES='acme/other=-'
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
jq -e '.outcome == "success" and ([.inputs.sources[].repository] == ["fixture","sibling"])' "$receipt" >/dev/null
unset PR_GATE_DEPENDENCIES
export GATE_RUNNER_FAMILY=fixture
printf 'PASS declared closure: dependency moves re-gate, unrelated moves reuse, undeclared reads and missing dependencies fail\n'

# Isolating the home/toolchain must not turn input hashing into a canned answer. A byte change
# with the same reported version still invalidates reuse, both for a compiler and a user helper.
# First bind the restored family/tool set, so each mutation below is the only changed input.
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
jq -e '.outcome == "success"' "$fixture/runner/attempts/acme-fixture-$head/last-result.json" >/dev/null
for changed_tool in "$fixture/toolchain/bin/rustc" "$fixture/home/.local/bin/fixture-helper"; do
  before_count=$(count)
  printf '# same version, different bytes\n' >>"$changed_tool"
  invoke
  [[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
  expect_count "$((before_count + 1))"
  jq -e '.outcome == "success"' "$fixture/runner/attempts/acme-fixture-$head/last-result.json" >/dev/null
  invoke
  [[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
  expect_count "$((before_count + 1))"
done
printf 'PASS fixture compiler and user-tool byte changes invalidate reuse without a version change\n'

# One shared ordinary-build cache per repository. Only a green merge-queue (or main-health) gate
# publishes it; a pull-request head reads it but never writes it; no slot keeps a copy between gates.
export PR_GATE_BUILD_CACHE_REPOS=acme/fixture
target="$fixture/runner/tree/fixture/target"
store="$fixture/runner/build-cache/acme/fixture"
queue_gate() { # a fresh replay on refs/queue/main/1, gated through the queue
  local qsha
  queued_n=$((${queued_n:-0} + 1))
  "$real_git" -C "$fixture/source" checkout -q -B "cache-queue-$queued_n" main
  printf 'replay %s\n' "$queued_n" >"$fixture/source/queued"
  "$real_git" -C "$fixture/source" add queued
  "$real_git" -C "$fixture/source" commit -qm "cache queue replay $queued_n"
  qsha=$("$real_git" -C "$fixture/source" rev-parse HEAD)
  "$real_git" -C "$fixture/source" push -q -f "$fixture/source.git" "HEAD:refs/queue/main/1"
  "$real_git" -C "$fixture/source" checkout -q main
  queue_entry "$qsha" refs/queue/main/1
  invoke
  rm -f "$fixture/queue.json"
  [[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
}
new_head
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
grep -q 'builds cold: no shared build cache' "$fixture/runner.log"
[[ ! -e "$store/current" && ! -e "$target/build-cache" ]] \
  || { printf 'a pull-request head wrote the shared cache or kept a slot copy\n' >&2; ls -laR "$store" "$target" >&2; exit 1; }
queue_gate
grep -q 'published acme/fixture build cache' "$fixture/runner.log" || { cat "$fixture/runner.log"; exit 1; }
read -r published _ <"$store/current"
[[ -f "$store/versions/$published/artifact" && ! -e "$target/build-cache" ]]
printf 'seeded\n' >"$store/versions/$published/seeded-marker"
mkdir -p "$target/llvm-cov-target" "$target/proof"
touch "$target/llvm-cov-target/stale.profraw" "$target/proof/report.json"
new_head
touch "$fixture/expect-seeded"
invoke --repo acme/fixture --pr 1
rm -f "$fixture/expect-seeded"
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
jq -e '.outcome == "success"' "$fixture/runner/attempts/acme-fixture-$head/last-result.json" >/dev/null \
  || { printf 'a seeded pull-request gate did not see the shared cache\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
grep -q "seeded acme/fixture build cache from shared version $published" "$fixture/runner.log"
[[ ! -e "$target/llvm-cov-target" && ! -e "$target/proof" && "$(cat "$store/current")" == "$published "* ]]
# Changed tool bytes change the key: the next gate builds cold even though a version exists.
printf 'changed compiler bytes\n' >"$fixture/tools/cache-tool-change"
new_head
touch "$fixture/expect-cold"
invoke --repo acme/fixture --pr 1
rm -f "$fixture/expect-cold" "$fixture/tools/cache-tool-change"
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
jq -e '.outcome == "success"' "$fixture/runner/attempts/acme-fixture-$head/last-result.json" >/dev/null
grep -q 'builds cold: no shared build cache' "$fixture/runner.log"
# A failed queue gate publishes nothing; the store keeps its version and the slot copy is gone.
touch "$fixture/fail-build-cache"
queue_gate
rm -f "$fixture/fail-build-cache"
[[ "$(cat "$store/current")" == "$published "* && ! -e "$target/build-cache" ]] \
  || { printf 'a failed queue gate changed the shared cache\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
# The next green queue gate replaces the version, and the old one is pruned.
queue_gate
read -r republished _ <"$store/current"
[[ "$republished" != "$published" && ! -e "$store/versions/$published" && -d "$store/versions/$republished" ]]
unset PR_GATE_BUILD_CACHE_REPOS
new_head
invoke
[[ "$runner_exit" == 0 && ! -e "$target/build-cache" ]]
printf 'PASS shared build cache: queue gates publish, pull-request heads only read, keys bind tools, failures publish nothing\n'

# Mutable execution inputs cannot retain a green verdict for the pre-recipe identity.
printf 'before\n' >"$fixture/tools/environment-probe"
touch "$fixture/mutate-tool"
before_count=$(count)
rm -f "$fixture/check-runs.jsonl"
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
receipt="$fixture/runner/attempts/acme-fixture-$head/last-result.json"
jq -e '.terminal and .outcome == "inputs_changed" and .exit_code == 0' "$receipt" >/dev/null
jq -se 'last.state == "error"' "$fixture/statuses.jsonl" >/dev/null
# One recipe per invocation: the re-run is the next tick's, never this unit run's.
expect_count "$((before_count + 1))"
jq -e '.inputs_changed_count == 1 and .inputs_changed_holds == false' "$receipt" >/dev/null
# The next scheduled ticks re-run it first and count the chain; the third drifted result holds it.
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
grep -q "re-running acme/fixture#1 at $head first" "$fixture/runner.log" \
  || { printf 'a drifted head was not re-run first\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
expect_count "$((before_count + 2))"
jq -e '.inputs_changed_count == 2 and .inputs_changed_holds == true' "$receipt" >/dev/null
invoke
expect_count "$((before_count + 3))"
jq -e '.inputs_changed_count == 3' "$receipt" >/dev/null
jq -se '[.[] | select(.status == "completed")] | length == 3 and
  all(.[]; .conclusion == "neutral" and (.output.summary | contains("Passed, but inputs changed during the run"))
    and (.output.summary | contains("✗") | not)) and
  (.[0].output.title | endswith("re-running on the next tick")) and
  (.[1].output.title | endswith("re-running on the next tick")) and
  (.[2].output.title | contains("stopped after two re-runs"))' "$fixture/check-runs.jsonl" >/dev/null
invoke
expect_count "$((before_count + 3))"
grep -q "hold acme/fixture@$head: inputs changed after two automatic re-runs" "$fixture/runner.log" \
  || { printf 'a thrice-drifted head was not held\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
# The escape: a forge re-gate request for the held head starts a new chain on a scheduled tick.
jq -nc --arg s "$head" '{requests:[{repo:"acme/fixture",number:1,head_sha:$s,requested_at:"2026-10-26T09:00:00Z",requested_by:"dana"}]}' \
  >"$fixture/regate.json"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 4))"
jq -e '.outcome == "inputs_changed" and .inputs_changed_count == 1' "$receipt" >/dev/null \
  || { printf 'a re-gate request did not start a new chain for a held head\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
rm -f "$fixture/regate.json"
before_count=$((before_count + 1))
# A re-run is a re-gate like any other: a merge burst defers it rather than racing it.
cp "$receipt" "$fixture/held-result.json"
jq '.inputs_changed_count = 1' "$fixture/held-result.json" >"$receipt"
touch "$fixture/runner/cache/mains/acme/fixture" 2>/dev/null || { mkdir -p "$fixture/runner/cache/mains/acme"; touch "$fixture/runner/cache/mains/acme/fixture"; }
GATE_RUNNER_REGATE_SETTLE=3600 invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 3))"
grep -q 'deferring re-gate of acme/fixture#1' "$fixture/runner.log" \
  || { printf 'a drifted re-run skipped merge-burst coalescing\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
# A truncated receipt reads as no chain and never kills the tick.
head -c 20 "$fixture/held-result.json" >"$receipt"
invoke
[[ "$runner_exit" == 0 ]] || { printf 'a truncated last-result.json killed the tick\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
expect_count "$((before_count + 4))"
jq -e '.inputs_changed_count == 1' "$receipt" >/dev/null
printf 'PASS passing input drift is neutral, re-runs first on the next two ticks (one recipe per tick, coalesced with a merge burst), then holds until a forge re-gate request; a truncated receipt never kills a tick\n'

# Changing only a sourced backoff library invalidates verified inputs and re-runs the recipe.
rm -f "$fixture/mutate-tool"
mkdir -p "$fixture/code"
cp "$script_dir/"pr-gate-*.sh "$fixture/code/"
original_script_dir=$script_dir
script_dir="$fixture/code"
before_count=$(count)
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 1))"
printf '# backoff-only installation change\n' >>"$script_dir/pr-gate-backoff.sh"
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 2))"
jq -r .inputs.tools "$fixture/runner/attempts/acme-fixture-$head/last-result.json" | grep -q '  pr-gate-backoff.sh$'
script_dir=$original_script_dir
printf 'PASS a backoff-only code change invalidates reuse and executes a new gate\n'

# A patch already on main still needs the real required gate, especially when the PR
# targets a different base. A failing recipe must never become a synthetic no-op green.
"$real_git" -C "$fixture/source" switch -q main
"$real_git" -C "$fixture/source" branch regression-release
"$real_git" -C "$fixture/source" switch -qc regression-already-upstream
printf 'fail\n' > "$fixture/source/mode"
printf 'same patch\n' > "$fixture/source/patch-proof"
"$real_git" -C "$fixture/source" add mode patch-proof
"$real_git" -C "$fixture/source" commit -qm 'topic patch with a failing recipe'
head=$("$real_git" -C "$fixture/source" rev-parse HEAD)
printf '%s\n' "$head" > "$fixture/head"
"$real_git" -C "$fixture/source" switch -q main
printf 'independent main change\n' > "$fixture/source/main-only"
"$real_git" -C "$fixture/source" add main-only
"$real_git" -C "$fixture/source" commit -qm 'main moved independently'
"$real_git" -C "$fixture/source" cherry-pick "$head" >/dev/null
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main regression-release regression-already-upstream
[[ "$("$real_git" -C "$fixture/source" cherry main "$head")" == "- $head" ]]
[[ "$("$real_git" -C "$fixture/source" merge-tree --write-tree main "$head")" == "$("$real_git" -C "$fixture/source" rev-parse main^{tree})" ]]
printf 'regression-release\n' > "$fixture/pr-base-ref"
before_count=$(count)
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 1))"
jq -se 'last.state == "failure"' "$fixture/statuses.jsonl" >/dev/null
jq -e '.terminal and .exit_code == 7' "$fixture/runner/attempts/acme-fixture-$head/last-result.json" >/dev/null
regate 2026-10-13T18:00:00Z
invoke
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 2))"
jq -se 'last.state == "failure"' "$fixture/statuses.jsonl" >/dev/null
printf 'PASS an already-upstream patch targeting another base runs the failing recipe and honours a requested re-gate\n'

# A forge 5xx is the forge failing, not a verdict: the runner retries the status post a bounded number
# of times, and when the forge stays down says so with an error status that the next tick gates past.
export PR_GATE_STATUS_ATTEMPTS=3 PR_GATE_STATUS_RETRY_SLEEP=0
before_count=$(count)
before_statuses=$(wc -l <"$fixture/statuses.jsonl")
printf '2\n' >"$fixture/forge-5xx"
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
grep -q 'forge answered 503 posting acme/fixture pending' "$fixture/runner.log" || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 1))"
printf 'PASS a flaky forge 5xx on the pending status is retried and the gate still runs\n'

# The newest status must not be this runner's own success, or the re-verify path posts no pending at all.
reset_newest_status() {
  jq -nc --arg sha "$("$real_git" -C "$fixture/source" rev-parse HEAD)" --argjson at "$(( $(wc -l <"$fixture/statuses.jsonl") + 1000 ))" \
    '{state:"failure",context:"fixture/required",description:"older failure",id:"older",updated_at:$at,sha:$sha,creator:{login:"runner-bot"}}' \
    >>"$fixture/statuses.jsonl"
}
reset_newest_status
printf '%s\n' -1 >"$fixture/forge-5xx"
: >"$fixture/forge-5xx.log"
before_count=$(count)
before_statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" != 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$before_count"
[[ "$(grep -c ' pending$' "$fixture/forge-5xx.log")" == 3 ]] || { cat "$fixture/forge-5xx.log"; exit 1; }
grep -q 'answered 503' "$fixture/runner.log" || { cat "$fixture/runner.log"; exit 1; }
printf '0\n' >"$fixture/forge-5xx"
rm -f "$fixture/forge-5xx"
printf 'PASS a persistent forge 5xx stops after the bounded retries without gating\n'

reset_newest_status
# Now with the forge refusing pending but accepting the error status posted after the retries.
printf '3\n' >"$fixture/forge-5xx"
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" != 0 ]] || { cat "$fixture/runner.log"; exit 1; }
jq -se '[.[-3:][] | select(.state == "error" and (.description | test("forge answered 503 posting pending")))] | length == 1' \
  "$fixture/statuses.jsonl" >/dev/null || { tail -3 "$fixture/statuses.jsonl" >&2; exit 1; }
rm -f "$fixture/forge-5xx"
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || { cat "$fixture/runner.log"; exit 1; }
expect_count "$((before_count + 1))"
printf 'PASS an exhausted forge 5xx leaves a visible error status and the next tick gates the head\n'

# ---- proof base (PR_GATE_PROOF_BASE_VARS) ----
# The recipe is told which base to prove against: origin/main for a main-bound PR, origin/<base> for a
# PR into a protected release line, and origin/main again -- said on the status -- for any other base.
# The base is part of the result, so a green proof against one base is never reused or kept green for
# another, and a forge that cannot answer for the base right now posts nothing until a cap.
export PR_GATE_PROOF_BASE_VARS=acme=ACME_PROOF_BASE_REF
rm -f "$fixture/forge-5xx" "$fixture/regate.json" "$fixture/queue.json"
: >"$fixture/proof-base.log"
"$real_git" -C "$fixture/source" checkout -q --orphan release/v1
printf 'release line\n' >"$fixture/source/release-note"
printf 'pass\n' >"$fixture/source/mode"
"$real_git" -C "$fixture/source" add release-note mode
"$real_git" -C "$fixture/source" commit -qm release-line
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" release/v1
relsha=$("$real_git" -C "$fixture/source" rev-parse HEAD)
"$real_git" -C "$fixture/source" checkout -q main
printf 'proof base head\n' >>"$fixture/source/marker"
printf 'pass\n' >"$fixture/source/mode"
"$real_git" -C "$fixture/source" add marker mode
"$real_git" -C "$fixture/source" commit -qm proof-base-head
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" main
"$real_git" -C "$fixture/source" rev-parse HEAD >"$fixture/head"
head=$(cat "$fixture/head")
mainsha=$head
refs_json() { # protected-branch...
  local rows=() b
  for b in main release/v1 topic; do
    local sha=$mainsha; [[ "$b" == main ]] || sha=$relsha
    local p=false; [[ " $* " == *" $b "* ]] && p=true
    rows+=("$(jq -nc --arg n "$b" --arg s "$sha" --argjson p "$p" '{name:$n,sha:$s,kind:"branch",protected:$p}')")
  done
  printf '%s\n' "${rows[@]}" | jq -sc . >"$fixture/refs.json"
}
refs_json main release/v1
last_status() { jq -sc --arg s "$1" '[.[] | select(.sha == $s and .context == "fixture/required")] | last' "$fixture/statuses.jsonl"; }
fail_pb() { printf '%s\n--- runner.log\n' "$1" >&2; cat "$fixture/runner.log" >&2; printf -- '--- proof-base.log\n' >&2; cat "$fixture/proof-base.log" >&2; exit 1; }

# A main-bound PR: origin/main, bound with main's sha, under the historical attempt key.
printf 'main\n' >"$fixture/pr-base-ref"
before_count=$(count)
invoke
[[ "$runner_exit" == 0 ]] || fail_pb 'main-bound PR: runner failed'
expect_count "$((before_count + 1))"
[[ "$(tail -n 1 "$fixture/proof-base.log")" == "origin/main $mainsha" ]] || fail_pb 'a main-bound PR was not proved against origin/main'
jq -e --arg s "$mainsha" '.inputs.proof_base == {variable:"ACME_PROOF_BASE_REF",branch:"main",sha:$s}' \
  "$fixture/runner/attempts/acme-fixture-$head/last-result.json" >/dev/null || fail_pb 'main proof base not in the inputs'
last_status "$head" | jq -e '.state == "success" and (.description | contains("proof base") | not)' >/dev/null \
  || fail_pb 'a main-bound success should name no proof base'
printf 'PASS proof base: a main-bound PR is proved against origin/main, bound into its inputs\n'

# The same head as a PR into the protected release line: origin/release/v1, its own attempt key, and
# pending is posted over the main-based green while it re-proves.
printf 'release/v1\n' >"$fixture/pr-base-ref"
before_count=$(count) before_statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke
[[ "$runner_exit" == 0 ]] || fail_pb 'release-line PR: runner failed'
expect_count "$((before_count + 1))"
[[ "$(tail -n 1 "$fixture/proof-base.log")" == "origin/release/v1 $relsha" ]] || fail_pb 'a release-line PR was not proved against origin/release/v1'
compgen -G "$fixture/runner/attempts/acme-fixture-$head.base-*-$relsha/last-result.json" >/dev/null \
  || fail_pb 'a release-line base has no attempt key of its own'
grep -q "its success was proved against origin/main, and it is now proved against origin/release/v1; posting pending" "$fixture/runner.log" \
  || fail_pb 'the listing did not retire a main-based green for a release-line PR'
# The listing's pending comes first, before any tree is prepared; then the gate's own pending and result.
[[ "$(grep -n 'posting pending' "$fixture/runner.log" | head -1 | cut -d: -f1)" -lt "$(grep -n '^.*preparing acme/fixture#1' "$fixture/runner.log" | head -1 | cut -d: -f1)" ]] \
  || fail_pb 'the stale green was retired only after preparation'
tail -n +"$((before_statuses + 1))" "$fixture/statuses.jsonl" | jq -se '.[0].state == "pending"
  and (.[0].description | startswith("its base changed: proved against origin/main, now waiting to be proved against origin/release/v1"))
  and any(.[]; .state == "pending" and (.description | contains("; proof base origin/release/v1")))
  and .[-1].state == "success" and (.[-1].description | contains("; proof base origin/release/v1"))' >/dev/null \
  || fail_pb 'release-line statuses do not name their base'

printf 'PASS proof base: a protected release line is proved against itself, under its own key, never kept green from main\n'

# Retargeted back to main (the exploit in review): the release-line green is neither reused nor kept
# green; main's proof re-runs and posts pending first. --list only reads: it retires nothing.
printf 'main\n' >"$fixture/pr-base-ref"
before_statuses=$(wc -l <"$fixture/statuses.jsonl")
"${runner_env[@]}" bash "$script_dir/pr-gate-runner.sh" --list >"$fixture/runner.log" 2>&1 || fail_pb '--list failed'
[[ "$(wc -l <"$fixture/statuses.jsonl")" == "$before_statuses" ]] || fail_pb '--list posted a status'
before_count=$(count) before_statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke
[[ "$runner_exit" == 0 ]] || fail_pb 'retarget: runner failed'
expect_count "$((before_count + 1))"
tail -n +"$((before_statuses + 1))" "$fixture/statuses.jsonl" | jq -se '.[0].state == "pending"
  and (.[0].description | startswith("its base changed: proved against origin/release/v1, now waiting to be proved against origin/main"))
  and .[-1].state == "success"' >/dev/null || fail_pb 'a release-line green stood for main'
# Once proved against its current base, the listing leaves the green alone.
before_statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke
[[ "$(wc -l <"$fixture/statuses.jsonl")" == "$before_statuses" ]] || fail_pb 'a green proved against the current base was retired'

[[ "$(tail -n 1 "$fixture/proof-base.log")" == "origin/main $mainsha" ]] || fail_pb 'the retargeted PR was not proved against main'
printf 'PASS proof base: a release-line green never stands for main after a retarget\n'

# An unprotected base is proved against origin/main, and the status says why.
printf 'topic\n' >"$fixture/pr-base-ref"
invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || fail_pb 'unprotected base: runner failed'
[[ "$(tail -n 1 "$fixture/proof-base.log")" == "origin/main $mainsha" ]] || fail_pb 'an unprotected base was used as the proof base'
last_status "$head" | jq -e '.state == "success" and (.description | contains("; proof base origin/main (topic is not a protected branch)"))' >/dev/null \
  || fail_pb 'the fallback to main is not said on the status'
# A forge without the ref listing degrades to main the same way, and says so.
mv "$fixture/refs.json" "$fixture/refs.json.off"
invoke --repo acme/fixture --pr 1
[[ "$(tail -n 1 "$fixture/proof-base.log")" == "origin/main $mainsha" ]] || fail_pb 'a forge without refs did not fall back to main'
last_status "$head" | jq -e '.description | contains("the forge does not report whether topic is protected")' >/dev/null \
  || fail_pb 'a forge without refs is not said on the status'
mv "$fixture/refs.json.off" "$fixture/refs.json"
printf 'PASS proof base: an unprotected base, or a forge that cannot say, is proved against origin/main and says so\n'

# A transient answer leaves the head with no status, counted; only the cap posts a failure, once; and
# a base that comes back gates the head and clears the count.
printf 'release/v1\n' >"$fixture/pr-base-ref"
touch "$fixture/refs-fail"
before_count=$(count) before_statuses=$(wc -l <"$fixture/statuses.jsonl")
for n in 1 2 3 4 5; do
  invoke
  [[ "$runner_exit" == 0 ]] || fail_pb "transient $n: runner failed"
  grep -q "proof base not available (the forge answered 503 listing acme/fixture branches); leaving it for the next tick, no status posted ($n of 6)" \
    "$fixture/runner.log" || fail_pb "transient $n was not left and counted"
done
[[ "$(wc -l <"$fixture/statuses.jsonl")" == "$before_statuses" ]] || fail_pb 'a transient base failure posted a status before the cap'
invoke
grep -q 'proof base still not available after 6 ticks' "$fixture/runner.log" || fail_pb 'the cap was not reached'
last_status "$head" | jq -e '.state == "failure" and (.description | startswith("no gate: proof base unavailable for 6 ticks"))' >/dev/null \
  || fail_pb 'the cap did not post a failure that says why'
capped=$(wc -l <"$fixture/statuses.jsonl")
invoke
[[ "$(wc -l <"$fixture/statuses.jsonl")" == "$capped" ]] || fail_pb 'the cap failure was posted again'
expect_count "$before_count"
rm -f "$fixture/refs-fail"
invoke
[[ "$runner_exit" == 0 ]] || fail_pb 'recovered base: runner failed'
expect_count "$((before_count + 1))"
last_status "$head" | jq -e '.state == "success"' >/dev/null || fail_pb 'a base that came back did not gate the head'
! compgen -G "$fixture/runner/cache/proof-base-wait/acme-fixture-$head*" >/dev/null || fail_pb 'the wait count was not cleared'
# A base the forge lists but will not serve is the same transient: nothing posted.
jq -c --arg s "$relsha" '. + [{name:"release/v2",sha:$s,kind:"branch",protected:true}]' "$fixture/refs.json" >"$fixture/refs.tmp"
mv "$fixture/refs.tmp" "$fixture/refs.json"
printf 'release/v2\n' >"$fixture/pr-base-ref"
before_statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke
grep -q 'proof base not available (base branch release/v2 could not be fetched' "$fixture/runner.log" || fail_pb 'an unfetchable base was not left for the next tick'
# (The retarget to release/v2 retires the old green with pending; the fetch failure itself posts nothing.)
tail -n +"$((before_statuses + 1))" "$fixture/statuses.jsonl" | jq -se 'all(.state == "pending" and (.description | startswith("its base changed")))' >/dev/null \
  || fail_pb 'an unfetchable base posted a status'
rm -rf "$fixture/runner/cache/proof-base-wait"
refs_json main release/v1
# A stale count never turns a later blip into a red status: an unchanged head reused on a base that is
# back clears it, so the next failure counts from one again.
printf 'release/v1\n' >"$fixture/pr-base-ref"
invoke   # settle on the release line again
touch "$fixture/refs-fail"
for n in 1 2 3 4 5; do invoke; done
rm -f "$fixture/refs-fail"
invoke
grep -qE "reuse acme/fixture@$head" "$fixture/runner.log" || fail_pb 'an unchanged head was not reused after the base came back'
! compgen -G "$fixture/runner/cache/proof-base-wait/acme-fixture-$head*" >/dev/null || fail_pb 'a reuse tick left the wait count'
before_statuses=$(wc -l <"$fixture/statuses.jsonl")
touch "$fixture/refs-fail"
invoke
rm -f "$fixture/refs-fail"
grep -q '(1 of 6)' "$fixture/runner.log" || fail_pb 'a later blip did not count from one'
[[ "$(wc -l <"$fixture/statuses.jsonl")" == "$before_statuses" ]] || fail_pb 'a later blip posted a status'
rm -rf "$fixture/runner/cache/proof-base-wait"
printf 'PASS proof base: a transient base failure posts nothing until the cap, once; a returning base gates the head and clears the count\n'

# A merge-queue entry is proved against the base its entry reports, not one parsed out of its ref.
"$real_git" -C "$fixture/source" checkout -q -B queue-release "$relsha"
printf 'queued onto the release line\n' >"$fixture/source/queued"
"$real_git" -C "$fixture/source" add queued
"$real_git" -C "$fixture/source" commit -qm queue-release
qrel=$("$real_git" -C "$fixture/source" rev-parse HEAD)
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" "+HEAD:refs/queue/7"
"$real_git" -C "$fixture/source" checkout -q main
jq -nc --arg s "$qrel" --arg h "$head" \
  '{entries:[{repo:"acme/fixture",number:1,base:"release/v1",queue_ref:"refs/queue/7",queue_sha:$s,pr_head_sha:$h}]}' >"$fixture/queue.json"
printf 'release/v1\n' >"$fixture/pr-base-ref"
invoke
[[ "$runner_exit" == 0 ]] || fail_pb 'queue: runner failed'
grep -q "preparing acme/fixture#1 at $qrel (merge queue refs/queue/7)" "$fixture/runner.log" || fail_pb 'the queue entry was not gated'
[[ "$(tail -n 1 "$fixture/proof-base.log")" == "origin/release/v1 $relsha" ]] || fail_pb "a queue entry was not proved against its entry's base"
# A forge that omits the field leaves the documented ref shape, refs/queue/<base>/<n>.
"$real_git" -C "$fixture/source" checkout -q -B queue-release-2 "$relsha"
printf 'queued again\n' >"$fixture/source/queued"
"$real_git" -C "$fixture/source" add queued
"$real_git" -C "$fixture/source" commit -qm queue-release-2
qrel2=$("$real_git" -C "$fixture/source" rev-parse HEAD)
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" "+HEAD:refs/queue/release/v1/1"
"$real_git" -C "$fixture/source" checkout -q main
jq -nc --arg s "$qrel2" --arg h "$head" \
  '{entries:[{repo:"acme/fixture",number:1,queue_ref:"refs/queue/release/v1/1",queue_sha:$s,pr_head_sha:$h}]}' >"$fixture/queue.json"
before_count=$(count) before_probes=$(wc -l <"$fixture/proof-base.log")
invoke
grep -q "preparing acme/fixture#1 at $qrel2 (merge queue refs/queue/release/v1/1)" "$fixture/runner.log" || fail_pb 'the second queue entry was not gated'
# Admitted, not only prepared: the recipe ran once more, its probe is a new line, and the queue commit
# got its own result.
! grep -q 'before admission' "$fixture/runner.log" || fail_pb 'a queue entry without base was refused at admission'
expect_count "$((before_count + 1))"
[[ "$(wc -l <"$fixture/proof-base.log")" == "$((before_probes + 1))" ]] || fail_pb 'the queue recipe did not run'
[[ "$(tail -n 1 "$fixture/proof-base.log")" == "origin/release/v1 $relsha" ]] || fail_pb 'a queue entry without base did not use its ref'
last_status "$qrel2" | jq -e '.state == "success" and (.description | contains("; proof base origin/release/v1"))' >/dev/null \
  || fail_pb 'the queue commit without base got no result'
rm -f "$fixture/queue.json"
printf 'PASS proof base: a merge-queue entry is proved against the base its entry reports, else its ref names\n'

# A malformed site entry degrades that owner to the recipe's own default instead of stopping the tick.
PR_GATE_PROOF_BASE_VARS='acme=' invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 0 ]] || fail_pb 'a malformed PR_GATE_PROOF_BASE_VARS stopped the tick'
grep -q "PR_GATE_PROOF_BASE_VARS: acme's entry is not a variable name" "$fixture/runner.log" || fail_pb 'a malformed entry was not named'
[[ "$(tail -n 1 "$fixture/proof-base.log")" == unset ]] || fail_pb 'a malformed entry still set a proof base'
# A proof-base variable that would overwrite a worker-root variable is refused at start.
PR_GATE_PROOF_BASE_VARS=acme=ACME_SPLIT_ROOT PR_GATE_WORKER_ROOT_VARS=ACME_SPLIT_ROOT invoke --repo acme/fixture --pr 1
[[ "$runner_exit" == 2 ]] && grep -q 'ACME_SPLIT_ROOT is also in PR_GATE_WORKER_ROOT_VARS' "$fixture/runner.log" \
  || fail_pb 'a proof-base variable colliding with a worker-root variable was accepted'
printf 'PASS proof base: a malformed site entry degrades its owner, not the tick; a colliding one is refused\n'

# A rate-limited ref listing is waited out, never counted towards a failure.
rm -rf "$fixture/runner/cache/proof-base-wait"
printf 'release/v1\n' >"$fixture/pr-base-ref"
touch "$fixture/refs-429"
invoke
rm -f "$fixture/refs-429" "$fixture/runner/cache/forge-backoff"
grep -q 'proof base not available (the forge is rate limiting this identity); leaving it for the next tick, not counted' "$fixture/runner.log" \
  || fail_pb 'a rate-limited ref listing was not left uncounted'
! compgen -G "$fixture/runner/cache/proof-base-wait/acme-fixture-$head*" >/dev/null || fail_pb 'a rate-limited ref listing was counted'
printf 'PASS proof base: a rate limit is waited out and never counted\n'

# Evidence that could not be published under one base, whose base then moved, is discharged as
# superseded -- kept, never published over the new base's result -- and the head is gated again.
"$real_git" -C "$fixture/source" checkout -q release/v1
printf 'release moved once\n' >>"$fixture/source/release-note"
"$real_git" -C "$fixture/source" add release-note
"$real_git" -C "$fixture/source" commit -qm release-move-1
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" release/v1
relsha=$("$real_git" -C "$fixture/source" rev-parse HEAD)
"$real_git" -C "$fixture/source" checkout -q main
refs_json main release/v1
touch "$fixture/reject-terminal"
invoke
rm -f "$fixture/reject-terminal"
[[ "$runner_exit" == 1 ]] || fail_pb 'a rejected publication was not left for recovery'
old_key=$(cd "$fixture/runner/attempts" && compgen -G "acme-fixture-$head.base-*-$relsha")
"$real_git" -C "$fixture/source" checkout -q release/v1
printf 'release moved twice\n' >>"$fixture/source/release-note"
"$real_git" -C "$fixture/source" add release-note
"$real_git" -C "$fixture/source" commit -qm release-move-2
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" release/v1
relsha=$("$real_git" -C "$fixture/source" rev-parse HEAD)
"$real_git" -C "$fixture/source" checkout -q main
refs_json main release/v1
before_count=$(count)
invoke
[[ "$runner_exit" == 0 ]] || fail_pb 'a moved base after a rejected publication: runner failed'
grep -q "discharged unpublished evidence of acme/fixture@${head:0:12} under $old_key" "$fixture/runner.log" || fail_pb 'the old base key was not discharged'
expect_count "$((before_count + 1))"
jq -e '.terminal and (.publication.required_status | not) and (.publication.superseded_by | startswith("proof base: "))
  and .recovery_required == null' "$fixture/runner/attempts/$old_key/last-result.json" >/dev/null || fail_pb 'the old evidence was not recorded as superseded'
last_status "$head" | jq -e --arg s "$relsha" '.state == "success" and (.description | contains("; proof base origin/release/v1"))' >/dev/null \
  || fail_pb 'the head was not gated against the moved base'
published=$(wc -l <"$fixture/statuses.jsonl")
invoke
[[ "$(wc -l <"$fixture/statuses.jsonl")" == "$published" ]] || fail_pb 'superseded evidence was published later'
printf 'PASS proof base: unpublished evidence under a base that moved is discharged as superseded, never published\n'

# One commit open as two pull requests, into release/v1 and into main: the status on that commit
# answers for both, so it is proved against main (the default branch), and says why.
printf 'release/v1\n' >"$fixture/pr-base-ref"
cp "$fixture/head" "$fixture/head2"
before_count=$(count)
invoke
[[ "$runner_exit" == 0 ]] || fail_pb 'shared head: runner failed'
expect_count "$((before_count + 1))"
[[ "$(tail -n 1 "$fixture/proof-base.log")" == "origin/main $("$real_git" -C "$fixture/source.git" rev-parse main)" ]] \
  || fail_pb 'a commit open in two PRs was not proved against main'
last_status "$head" | jq -e '.state == "success" and (.description | contains("; proved against main: this commit is open in 2 PRs"))
  and (.description | contains("proof base origin/release") | not)' >/dev/null || fail_pb 'the shared-head status does not say why it is main'
compgen -G "$fixture/runner/attempts/acme-fixture-$head/last-result.json" >/dev/null \
  && jq -e '.inputs.proof_base.branch == "main"' "$fixture/runner/attempts/acme-fixture-$head/last-result.json" >/dev/null \
  || fail_pb 'the shared-head proof base is not main in the inputs'
# The second PR of the same commit reuses that result: one proof, no flapping between bases.
invoke
expect_count "$((before_count + 1))"
rm -f "$fixture/head2"
printf 'PASS proof base: a commit open in two PRs (main and a release line) is proved against main and says so\n'

# A word without "=" is malformed, not a collision: it degrades (here: names no owner), never refuses.
PR_GATE_PROOF_BASE_VARS=ACME_SPLIT_ROOT PR_GATE_WORKER_ROOT_VARS=ACME_SPLIT_ROOT invoke --list
[[ "$runner_exit" == 0 ]] || fail_pb 'a word without = was refused at start'

# --branch: the tip of a protected branch is gated with the normal recipe, proved against the branch as
# it stood before the tip (its first parent: proved against itself every base-relative check would see
# an empty diff), and posted as <repo>/required on the tip.
printf 'main\n' >"$fixture/pr-base-ref"
relparent=$("$real_git" -C "$fixture/source.git" rev-parse "$relsha^1")
before_count=$(count) before_statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke --branch release/v1 --repo acme/fixture
[[ "$runner_exit" == 0 ]] || fail_pb '--branch: runner failed'
expect_count "$((before_count + 1))"
grep -q "preparing acme/fixture release/v1 at $relsha" "$fixture/runner.log" || fail_pb '--branch did not gate the tip'
[[ "$(tail -n 1 "$fixture/proof-base.log")" == "origin/release/v1~1 $relparent" ]] || fail_pb '--branch was not proved against the branch before its tip'
tail -n +"$((before_statuses + 1))" "$fixture/statuses.jsonl" | jq -se --arg s "$relsha" --arg p "${relparent:0:12}" 'all(.sha == $s and .context == "fixture/required")
  and .[-1].state == "success"
  and (.[-1].description | test("; inputs [0-9a-f]{64}; proof base origin/release/v1 before this commit \\(" + $p + "\\)"))' >/dev/null \
  || fail_pb '--branch did not post <repo>/required on the tip, naming its base'
jq -e --arg p "$relparent" '.inputs.proof_base == {variable:"ACME_PROOF_BASE_REF",branch:"release/v1",sha:$p}' \
  "$(compgen -G "$fixture/runner/attempts/acme-fixture-$relsha.base-*-$relsha/last-result.json")" >/dev/null \
  || fail_pb '--branch did not bind the parent as its proof base'
# A tip that already carries a required success is never re-proved over.
invoke --branch release/v1
[[ "$runner_exit" == 0 ]] || fail_pb '--branch second pass: runner failed'
expect_count "$((before_count + 1))"
grep -q "skip acme/fixture release/v1: its tip ${relsha:0:12} already carries a fixture/required success" "$fixture/runner.log" \
  || fail_pb 'a tip with a required success was gated again'
# A tip authored as the gate identity is its own work: refused, nothing posted.
"$real_git" -C "$fixture/source" checkout -q release/v1
printf 'by the gate\n' >>"$fixture/source/release-note"
"$real_git" -C "$fixture/source" add release-note
"$real_git" -C "$fixture/source" -c user.name=runner-bot -c user.email=bot@example.invalid commit -qm by-the-gate
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" release/v1
relsha=$("$real_git" -C "$fixture/source" rev-parse HEAD)
refs_json main release/v1
before_statuses=$(wc -l <"$fixture/statuses.jsonl")
invoke --branch release/v1 --repo acme/fixture
grep -q "authored or committed as runner-bot, which this runner must not prove" "$fixture/runner.log" || fail_pb 'the gate identity proved its own tip'
expect_count "$((before_count + 1))"
[[ "$(wc -l <"$fixture/statuses.jsonl")" == "$before_statuses" ]] || fail_pb 'a refused own tip got a status'
# A failing tip is held like a PR head's failure: a scheduled pass on identical inputs runs nothing.
printf 'fail\n' >"$fixture/source/mode"
"$real_git" -C "$fixture/source" add mode
"$real_git" -C "$fixture/source" commit -qm release-fails
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" release/v1
relsha=$("$real_git" -C "$fixture/source" rev-parse HEAD)
"$real_git" -C "$fixture/source" checkout -q main
refs_json main release/v1
invoke --branch release/v1
expect_count "$((before_count + 2))"
last_status "$relsha" | jq -e '.state == "failure"' >/dev/null || fail_pb 'a failing tip did not post failure'
invoke --branch release/v1
expect_count "$((before_count + 2))"
grep -q "hold acme/fixture@$relsha" "$fixture/runner.log" || fail_pb 'a failing tip was not held'
# A drifting tip is never held: --branch reads no forge re-gate request, so a hold could not be lifted.
# Each scheduled pass runs one recipe and counts the chain past three.
"$real_git" -C "$fixture/source" checkout -q release/v1
printf 'pass\n' >"$fixture/source/mode"
"$real_git" -C "$fixture/source" add mode
"$real_git" -C "$fixture/source" commit -qm release-drifts
"$real_git" -C "$fixture/source" push -q "$fixture/source.git" release/v1
relsha=$("$real_git" -C "$fixture/source" rev-parse HEAD)
"$real_git" -C "$fixture/source" checkout -q main
refs_json main release/v1
touch "$fixture/mutate-tool"
for pass in 1 2 3 4; do
  invoke --branch release/v1
  [[ "$runner_exit" == 0 ]] || fail_pb "--branch drift pass $pass: runner failed"
  expect_count "$((before_count + 2 + pass))"
done
! grep -q "hold acme/fixture@$relsha" "$fixture/runner.log" || fail_pb 'a drifting branch tip was held'
jq -e '.outcome == "inputs_changed" and .inputs_changed_count == 4 and .inputs_changed_holds == false' \
  "$(compgen -G "$fixture/runner/attempts/acme-fixture-$relsha.base-*/last-result.json")" >/dev/null \
  || fail_pb 'a drifting branch tip did not count its chain unheld'
! tail -n 1 "$fixture/check-runs.jsonl" | jq -e '.output.title | contains("stopped after two re-runs")' >/dev/null \
  || fail_pb 'an unheld branch tip was labelled held'
rm -f "$fixture/mutate-tool"
before_count=$((before_count + 4))
# Refusals: unprotected, an owner without a proof-base variable, and the other modes.
invoke --branch topic --repo acme/fixture
[[ "$runner_exit" == 1 ]] || fail_pb 'an unprotected branch was not refused'
grep -q 'refusing acme/fixture topic: the forge does not report it as protected' "$fixture/runner.log" || fail_pb 'the refusal does not say why'
PR_GATE_PROOF_BASE_VARS='' invoke --branch release/v1 --repo acme/fixture
[[ "$runner_exit" == 1 ]] && grep -q 'acme has no PR_GATE_PROOF_BASE_VARS entry' "$fixture/runner.log" \
  || fail_pb 'an owner without a proof-base variable was gated'
invoke --branch release/v1 --pr 1
[[ "$runner_exit" == 2 ]] || fail_pb '--branch with --pr was accepted'
invoke --branch release/v1 --main-health
[[ "$runner_exit" == 2 ]] || fail_pb '--branch with --main-health was accepted'
expect_count "$((before_count + 2))"
unset PR_GATE_PROOF_BASE_VARS
printf 'PASS --branch: a protected tip is proved against the branch before it, posted as <repo>/required, held, never re-proved over, never held on input drift, and refused when it may not be\n'
