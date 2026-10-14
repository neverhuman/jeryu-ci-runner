#!/usr/bin/env bash
# Contributed heads: nothing runs without a maintainer's ok-to-test for the exact head, and what does
# run goes through the site's sandbox with none of this host's credentials. Fixture forge, fake
# sandbox, fake recipe; offline, invented site data only.
set -euo pipefail
# A gate may run this suite inside a pr-gate-runner whose environment would steer the runner under
# test (see test-pr-gate-runner.sh). Start clean, and bring our own invented site configuration.
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/tools"
real_git=$(command -v git)
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
        https://forge.invalid/git/acme/*.git) name=${args[$index]##*/}; args[$index]="$FAKE_FORGE/source.git";;
      esac
    done;;
esac
exec "$REAL_GIT" "${args[@]}"
SH
# The recipe: it counts its executions and records where and how it ran, so the assertions can tell a
# sandboxed execution from a host one.
cat >"$fixture/tools/just" <<SH
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == --summary ]]; then printf 'required\n'; exit; fi
[[ "\${1:-}" == required ]]
count=0
[[ ! -f "$fixture/executions" ]] || read -r count <"$fixture/executions"
printf '%s\n' "\$((count + 1))" >"$fixture/executions"
printf '%s\n' "\${PR_GATE_SANDBOX:-0}" >"$fixture/last-recipe-sandbox"
mkdir -p target
[[ "\$(cat mode)" == pass ]] || exit 7
SH
# The site's sandbox: here a script that records the argv and the complete environment it was given,
# then runs the recipe in the tree it was handed. A real one puts the tree in an ephemeral,
# network-restricted VM or container first.
cat >"$fixture/tools/fake-sandbox" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>"$fixture/sandbox-argv"
env >"$fixture/sandbox-env"
count=0
[[ ! -f "$fixture/sandbox-runs" ]] || read -r count <"$fixture/sandbox-runs"
printf '%s\n' "\$((count + 1))" >"$fixture/sandbox-runs"
root=\$1 repo=\$2; shift 2
cd "\$root/\$repo"
exec "\$@"
SH
cat >"$fixture/tools/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
method=GET payload='{}'
while (($#)); do
  case "$1" in -X) method=$2; shift 2;; --data) payload=$2; shift 2;; *) url=$1; shift;; esac
done
head=$(cat "$FAKE_FORGE/head")
labels='[]'
[[ ! -f "$FAKE_FORGE/labels.json" ]] || labels=$(cat "$FAKE_FORGE/labels.json")
case "$method $url" in
  # jeryu's own rows carry the origin marking as labels; the GitHub-compatible v3 read has none.
  'GET '*'/pulls?state=open')
    jq -nc --arg sha "$head" --argjson labels "$labels" '{items:[{number:1,head_sha:$sha,labels:$labels}]}'
    printf '\n200';;
  'GET '*'/api/v1/repos/'*'/pulls/1')
    jq -nc --arg sha "$head" --argjson labels "$labels" '{number:1,head_sha:$sha,labels:$labels}'
    printf '\n200';;
  'GET '*'/pulls/1')
    jq -nc --arg sha "$head" '{state:"open",user:{login:"author"},head:{sha:$sha,ref:"author/feature"}}'
    printf '\n200';;
  'GET '*'/gate-allowances'*)
    if [[ -f "$FAKE_FORGE/refuse-allowances" ]]; then printf '{"message":"denied"}\n403'; exit; fi
    if [[ -f "$FAKE_FORGE/allowances.json" ]]; then cat "$FAKE_FORGE/allowances.json"; else printf '{"allowances":[]}'; fi
    printf '\n200';;
  'GET '*'/gate-regate'*) printf '{"requests":[]}\n200';;
  'GET '*'/merge-queue?state=building') printf '{"entries":[]}\n200';;
  'GET '*'/status')
    commit=${url%/status}; commit=${commit##*/}
    if [[ -f "$FAKE_FORGE/statuses.jsonl" ]]; then
      jq -sc --arg c "$commit" '{statuses:[.[] | select(.sha == $c)]}' "$FAKE_FORGE/statuses.jsonl"
    else printf '{"statuses":[]}'; fi
    printf '\n200';;
  'POST '*'/statuses/'*)
    count=0
    [[ ! -f "$FAKE_FORGE/statuses.jsonl" ]] || count=$(wc -l <"$FAKE_FORGE/statuses.jsonl")
    result=$(jq -c --arg id "status-$count" --argjson clock "$count" --arg sha "${url##*/statuses/}" \
      '. + {id:$id,updated_at:$clock,sha:$sha}' <<<"$payload")
    printf '%s\n' "$result" >>"$FAKE_FORGE/statuses.jsonl"
    printf '%s\n201' "$result";;
  'POST '*'/check-runs')
    printf '%s\n' "$payload" >>"$FAKE_FORGE/check-runs.jsonl"
    printf '{"id":"check"}\n201';;
  'POST '*'/heartbeat') printf '{"accepted":true}\n200';;
  *) printf '{"message":"unexpected fixture route"}\n404';;
esac
SH
chmod +x "$fixture/tools/"*
export FAKE_FORGE="$fixture" REAL_GIT="$real_git"

cat >"$fixture/pr-gate.env" <<ENV
# invented site for this suite
PR_GATE_FORGE_URL="https://forge.invalid"
JERYU_TOKEN_FILE=$fixture/token
GATE_RUNNER_IDENTITY='runner-bot'
PR_GATE_PRIMARY_OWNER=acme
# PR_GATE_CONTRIBUTED_LABEL stays at its default, origin:contributed: the marking jeryu-deploy puts on a row.
PR_GATE_OK_TO_TEST_MAINTAINERS="dana robin"
PR_GATE_SANDBOX_COMMAND="$fixture/tools/fake-sandbox"
PR_GATE_SANDBOX_PATH="$fixture/tools:/usr/local/bin:/usr/bin:/bin"
ENV
export PR_GATE_CONFIG="$fixture/pr-gate.env"
export GATE_RUNNER_HOME="$fixture/runner" GATE_RUNNER_TOOLS="$fixture/tools"
export GATE_RUNNER_REPOS=acme/fixture GATE_RUNNER_FAMILY=fixture GATE_RUNNER_SCCACHE=""
export PR_GATE_BUILD_CACHE_REPOS=acme/fixture
export GATE_RUNNER_SLOT=0 GATE_RUNNER_REGATE_SETTLE=0
export PATH="$fixture/tools:/usr/local/bin:/usr/bin:/bin"

invoke() {
  runner_exit=0
  bash "$script_dir/pr-gate-runner.sh" "$@" >"$fixture/runner.log" 2>&1 || runner_exit=$?
  [[ "$runner_exit" == 0 ]] || { printf 'the runner exited %s\n' "$runner_exit"; cat "$fixture/runner.log"; exit 1; }
}
count() { cat "$fixture/executions" 2>/dev/null || printf '0\n'; }
expect_count() {
  local want=$1 got; got=$(count)
  [[ "$got" == "$want" ]] && return
  printf 'expected %s recipe executions, got %s\n--- runner.log\n' "$want" "$got" >&2
  cat "$fixture/runner.log" >&2
  exit 1
}
statuses() { { wc -l <"$fixture/statuses.jsonl" || printf '0\n'; } 2>/dev/null; }
label() { printf '%s\n' "$1" >"$fixture/labels.json"; }
allow() { # head-sha who [label]
  jq -nc --arg s "$1" --arg by "$2" --arg l "${3:-ok-to-test}" \
    '{allowances:[{repo:"acme/fixture",number:1,head_sha:$s,label:$l,allowed_by:$by,
                   allowed_at:"2026-10-06T09:00:00Z"}]}' >"$fixture/allowances.json"
}
head_sha() { cat "$fixture/head"; }

# A contribution with no allowance at all: nothing is executed and nothing is posted on the PR. It is
# not a failure -- the head is simply waiting for a maintainer.
label '["origin:contributed"]'
invoke
expect_count 0
[[ "$(statuses)" == 0 ]] || { printf 'an unallowed contribution was given a status\n' >&2; cat "$fixture/statuses.jsonl" >&2; exit 1; }
grep -q 'not running acme/fixture#1 (contributed): no ok-to-test from a maintainer' "$fixture/runner.log" \
  || { printf 'the refusal was not reported\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
[[ ! -e "$fixture/runner/tree/fixture" ]] || { printf 'an unallowed contribution was checked out\n' >&2; exit 1; }
printf 'PASS a contribution with no ok-to-test runs nothing and posts nothing\n'

# An allowance from somebody who is not a configured maintainer is not an allowance.
allow "$(head_sha)" mallory
invoke
expect_count 0
grep -q 'came from mallory, who is not a configured maintainer' "$fixture/runner.log" \
  || { printf 'an outsider allowance was not named\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
# Nor is one that came from some other label.
allow "$(head_sha)" dana lgtm
invoke
expect_count 0
grep -q 'allowed by lgtm, which is not ok-to-test' "$fixture/runner.log" \
  || { printf 'an allowance from another label was not named\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
# Nor one this runner cannot read: a forge that refuses the route allows nothing.
allow "$(head_sha)" dana
touch "$fixture/refuse-allowances"
invoke
expect_count 0
grep -q 'the forge answered 403 for its ok-to-test allowances' "$fixture/runner.log" \
  || { printf 'a refused allowance list did not stop the contribution\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
rm -f "$fixture/refuse-allowances"
printf 'PASS an allowance from a non-maintainer, another label, or an unreadable route runs nothing\n'

# A stale allowance: the maintainer allowed the head that was pushed over. A push spends the ok-to-test.
stale=$(head_sha)
printf 'pass\nagain\n' >"$fixture/source/mode"
git -C "$fixture/source" add mode
git -C "$fixture/source" commit -qm second-push
git -C "$fixture/source" push -q "$fixture/source.git" main
git -C "$fixture/source" rev-parse HEAD >"$fixture/head"
allow "$stale" dana
invoke
expect_count 0
[[ "$(statuses)" == 0 ]] || { printf 'a stale allowance produced a status\n' >&2; exit 1; }
grep -q "ok-to-test names ${stale:0:12}, not this head: a push spends it" "$fixture/runner.log" \
  || { printf 'a stale allowance was not named\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
printf 'PASS an ok-to-test left over from an earlier head runs nothing\n'

# Allowed by a maintainer for exactly this head: it runs, once, and only through the sandbox.
printf 'pass\n' >"$fixture/source/mode"
git -C "$fixture/source" add mode
git -C "$fixture/source" commit -qm allowed-head
git -C "$fixture/source" push -q "$fixture/source.git" main
git -C "$fixture/source" rev-parse HEAD >"$fixture/head"
allow "$(head_sha)" robin
mkdir -p "$fixture/runner/cache/build-target/0/acme"
printf '%064d\n' 1 >"$fixture/runner/cache/build-target/0/acme/fixture"
# An enrolled sibling sharing the slot tree: the sandbox could write into its retained cache, so the
# contribution must leave neither its authorization nor its outputs for a later trusted gate.
printf '%064d\n' 2 >"$fixture/runner/cache/build-target/0/acme/sibling"
mkdir -p "$fixture/runner/tree/sibling/target/build-cache/debug"
printf 'planted\n' >"$fixture/runner/tree/sibling/target/build-cache/debug/build-script-build"
invoke
expect_count 1
[[ ! -e "$fixture/runner/cache/build-target/0/acme/fixture" ]] || {
  printf 'a contribution retained ordinary-build cache authorization\n' >&2; exit 1;
}
[[ ! -e "$fixture/runner/cache/build-target/0/acme/sibling" ]] || {
  printf 'a contribution left a sibling cache authorized in its slot\n' >&2; exit 1;
}
[[ ! -e "$fixture/runner/tree/sibling/target/build-cache" ]] || {
  printf 'a contribution left a sibling build cache it could have written\n' >&2; exit 1;
}
[[ "$(cat "$fixture/sandbox-runs")" == 1 ]] || { printf 'the recipe did not go through the sandbox\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
[[ "$(cat "$fixture/last-recipe-sandbox")" == 1 ]] || { printf 'the recipe did not see a sandbox\n' >&2; exit 1; }
jq -se 'last.state=="success" and (last.description|contains("sandboxed-contribution"))' "$fixture/statuses.jsonl" >/dev/null \
  || { printf 'the sandboxed result was not published\n' >&2; cat "$fixture/statuses.jsonl" >&2; exit 1; }
receipt="$fixture/runner/attempts/acme-fixture-$(head_sha)/last-result.json"
jq -e '.execution_kind=="sandboxed-contribution" and .inputs.execution_kind=="sandboxed-contribution"
  and .outcome=="success"' "$receipt" >/dev/null \
  || { printf 'the receipt does not record a sandboxed execution\n' >&2; jq -c . "$receipt" >&2; exit 1; }
# The sandbox was handed the tree and the repository, and then the repository's own recipe.
grep -qx "$fixture/runner/tree fixture just required" "$fixture/sandbox-argv" \
  || { printf 'the sandbox was called with %s\n' "$(cat "$fixture/sandbox-argv")" >&2; exit 1; }
printf 'PASS an allowed contribution runs exactly once, in the sandbox, and publishes its result\n'

# What the sandbox was given: no credential, no gate identity, no host home, no governed tools, no
# shared cache. This is the test that the sandbox cannot reach the forge as the gate.
sandbox_env="$fixture/sandbox-env"
grep -q '^PR_GATE_SANDBOX=1$' "$sandbox_env" || { printf 'the sandbox was not told it is one\n' >&2; exit 1; }
if grep -q 'synthetic-fixture-token' "$sandbox_env"; then
  printf 'the sandbox environment carries the forge token\n' >&2; exit 1
fi
for forbidden in JERYU_TOKEN_FILE JERYU_BASE GATE_RUNNER_IDENTITY GATE_RUNNER_HOME GATE_RUNNER_TOOLS \
    PR_GATE_CONFIG PR_GATE_FORGE_URL HOME USER RUSTC_WRAPPER SCCACHE_DIR SCCACHE_SERVER_PORT \
    CARGO_HOME SSH_AUTH_SOCK JERYU_CI_BUILD_CACHE_DIR; do
  if grep -q "^$forbidden=" "$sandbox_env"; then
    printf 'the sandbox environment carries %s\n' "$forbidden" >&2; grep "^$forbidden=" "$sandbox_env" >&2; exit 1
  fi
done
# Its PATH is the site's sandbox path, which is not the gate's governed tools directory.
grep -qx "PATH=$fixture/tools:/usr/local/bin:/usr/bin:/bin" "$sandbox_env" \
  || { printf 'the sandbox PATH was %s\n' "$(grep '^PATH=' "$sandbox_env")" >&2; exit 1; }
grep -q 'skips the locked-crate prefetch' "$fixture/runner.log" \
  || { printf 'a contribution was prefetched into the shared registry\n' >&2; exit 1; }
# And it built in its own tree, not in a directory another gate reads.
[[ -d "$fixture/runner/tree/fixture/target" && ! -L "$fixture/runner/tree/fixture/target" ]] \
  || { printf 'a contribution built through a shared target link\n' >&2; exit 1; }
printf 'PASS the sandbox gets no token, identity, home, governed tools or shared cache\n'

# A contribution that changes what the gate itself evaluates with is recorded and named on its check
# run; the required status stays the gate's own verdict.
git -C "$fixture/source" checkout -q -b contribution
printf 'required:\n\techo gate\n' >"$fixture/source/Justfile"
mkdir -p "$fixture/source/ops/ci"
printf 'echo ci\n' >"$fixture/source/ops/ci/pr-ci.sh"
printf 'note\n' >"$fixture/source/README"
git -C "$fixture/source" add Justfile ops/ci/pr-ci.sh README
git -C "$fixture/source" commit -qm 'touch the gate inputs'
git -C "$fixture/source" push -q "$fixture/source.git" contribution
git -C "$fixture/source" rev-parse HEAD >"$fixture/head"
git -C "$fixture/source" checkout -q main
allow "$(head_sha)" dana
invoke
expect_count 2
receipt="$fixture/runner/attempts/acme-fixture-$(head_sha)/last-result.json"
jq -e '.gate_input_paths == ["Justfile","ops/ci/pr-ci.sh"]' "$receipt" >/dev/null \
  || { printf 'the changed gate inputs were not recorded: %s\n' "$(jq -c '.gate_input_paths' "$receipt")" >&2; exit 1; }
jq -se 'last.output.summary | contains("gate inputs changed: extra review required")' "$fixture/check-runs.jsonl" >/dev/null \
  || { printf 'the check run did not name the gate-input change\n' >&2; jq -c 'last' "$fixture/check-runs.jsonl" >&2; exit 1; }
jq -se 'last.description | contains("gate inputs changed") | not' "$fixture/statuses.jsonl" >/dev/null \
  || { printf 'the gate-input note leaked into the required status\n' >&2; jq -c 'last' "$fixture/statuses.jsonl" >&2; exit 1; }
grep -q 'changes gate inputs (Justfile ops/ci/pr-ci.sh): extra review required' "$fixture/runner.log" \
  || { printf 'the gate-input change was not reported\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
printf 'PASS a contribution that changes the gate inputs is recorded and named for extra review\n'

# Allowed, but the site configured no sandbox: a contribution runs nowhere else.
label '["origin:contributed","ok-to-test"]'
before=$(count)
grep -v '^PR_GATE_SANDBOX_COMMAND=' "$fixture/pr-gate.env" >"$fixture/no-sandbox.env"
PR_GATE_CONFIG="$fixture/no-sandbox.env" invoke --repo acme/fixture --pr 1
expect_count "$before"
grep -q 'PR_GATE_SANDBOX_COMMAND is not configured, and a contribution runs nowhere else' "$fixture/runner.log" \
  || { printf 'a missing sandbox was not named\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
printf 'PASS with no sandbox configured, an allowed contribution still runs nothing\n'

# An internal PR is unchanged: no label, no allowance, and it runs on the gate host as before.
git -C "$fixture/source" rev-parse main >"$fixture/head"
printf '["origin:internal"]\n' >"$fixture/labels.json"
rm -f "$fixture/allowances.json" "$fixture/sandbox-runs"
before=$(count)
invoke --repo acme/fixture --pr 1
expect_count "$((before + 1))"
[[ ! -f "$fixture/sandbox-runs" ]] || { printf 'an internal PR was sent to the sandbox\n' >&2; exit 1; }
[[ "$(cat "$fixture/last-recipe-sandbox")" == 0 ]] || { printf 'an internal recipe saw PR_GATE_SANDBOX\n' >&2; exit 1; }
jq -se 'last.state=="success" and (last.description|contains("operator-unsealed"))' "$fixture/statuses.jsonl" >/dev/null \
  || { printf 'an internal PR did not keep its own path\n' >&2; jq -c 'last' "$fixture/statuses.jsonl" >&2; exit 1; }
jq -e '.execution_kind=="operator-unsealed" and (has("gate_input_paths")|not)' \
  "$fixture/runner/attempts/acme-fixture-$(head_sha)/last-result.json" >/dev/null \
  || { printf 'an internal receipt was labelled as a contribution\n' >&2; exit 1; }
printf 'PASS an internal PR keeps the operator path, with no allowance and no sandbox\n'

# A malformed allowance is named and ignored, never guessed at.
label '[{"name":"origin:contributed"}]'   # a forge that spells labels the GitHub way
jq -nc '{allowances:[{repo:"acme/fixture",number:1,head_sha:"not-a-sha",allowed_by:"dana"}]}' \
  >"$fixture/allowances.json"
before=$(count)
invoke
expect_count "$before"
grep -q 'ignoring a malformed ok-to-test allowance: acme/fixture#1' "$fixture/runner.log" \
  || { printf 'a malformed allowance was not named\n' >&2; cat "$fixture/runner.log" >&2; exit 1; }
printf 'PASS a malformed ok-to-test allowance is named and ignored\n'
