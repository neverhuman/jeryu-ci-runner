#!/usr/bin/env bash
set -euo pipefail
# A gate may run this suite inside a pr-gate-runner whose environment reaches the recipe. Its
# GATE_RUNNER_*/JERYU_*/PR_GATE_* variables would then steer the code under test. Start clean.
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
# shellcheck source=ops/pr-gate/bin/pr-gate-state.sh
source "$script_dir/pr-gate-state.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
owner=acme repo=fixture SLOT=0 MARKER=pr-gate-runner@test
sha=0123456789012345678901234567890123456789
HOME_DIR="$scratch/state"
mkdir -p "$HOME_DIR"
publication_mode=201
api() {
  code=$publication_mode
  if [[ "$code" != 201 ]]; then body='{"message":"rejected"}'; return; fi
  export body='{"id":"verified-publication-id"}'
  printf '%s\n' "$3" >>"$scratch/published.jsonl"
}
identity="$scratch/inputs.json"
printf '{"source":"%s","dependencies":"closed","toolchain":"pinned","fixtures":"verified"}\n' "$sha" >"$identity"
statuses="$scratch/statuses.json"
printf '{"statuses":[{"context":"fixture/required","state":"success","id":"verified-publication-id","created_at":"2026-09-17T00:00:00Z"}]}' >"$statuses"
gate_lock "acme-fixture-$sha"
: "${gate_key_dir:?}"
gate_begin "$identity"
: "${gate_attempt_dir:?}" "${gate_receipt:?}"
printf 'error: deliberate negative test\nall tests passed\n' >"$gate_attempt_dir/build.log"
gate_finish success 0 "$gate_attempt_dir/build.log"
gate_publish
gate_decision "$identity" 0 "$statuses"
[[ "${gate_action:?}" == reuse ]]
jq -e '.exit_code==0 and .outcome=="success" and .terminal' "$gate_receipt" >/dev/null
printf 'PASS success uses process exit, verified log and current publication\n'

jq '.statuses += [{context:"fixture/required",state:"failure",id:"newer",created_at:"2026-09-18T00:00:00Z"}]' \
  "$statuses" >"$scratch/overridden.json"
gate_decision "$identity" 0 "$scratch/overridden.json"
[[ "$gate_action" == run ]]
printf 'PASS newer failure invalidates successful reuse\n'

gate_begin "$identity"
printf 'failed test\n' >"$gate_attempt_dir/build.log"
gate_finish failure 7 "$gate_attempt_dir/build.log"
gate_publish
gate_decision "$identity" 0 "$statuses"
[[ "$gate_action" == hold ]]
gate_decision "$identity" 1 "$statuses"
[[ "$gate_action" == run ]]
for input in source dependencies toolchain fixtures; do
  jq --arg input "$input" '.[$input]="changed"' "$identity" >"$scratch/changed.json"
  gate_decision "$scratch/changed.json" 0 "$statuses"
  [[ "$gate_action" == run ]]
done
printf 'PASS deterministic failure needs explicit retry or changed bound inputs\n'

gate_begin "$identity"
printf 'passed\n' >"$gate_attempt_dir/build.log"
gate_finish success 0 "$gate_attempt_dir/build.log"
publication_mode=403
if gate_publish; then exit 1; fi
jq -e '.terminal and .exit_code==0 and .recovery_required!=null and (.publication.required_status|not)' "$gate_receipt" >/dev/null
gate_decision "$identity" 0 "$statuses"
[[ "$gate_action" == republish ]]
publication_mode=201
gate_recover
gate_decision "$identity" 0 "$statuses"
[[ "$gate_action" == reuse ]]
printf 'PASS publication rejection persists terminal evidence and replays without computation\n'

log=$(jq -r '.log' "$gate_key_dir/last-result.json")
printf 'tampered\n' >>"$log"
gate_decision "$identity" 0 "$statuses"
[[ "$gate_action" == run ]]
printf 'PASS modified evidence cannot authorize reuse\n'

gate_begin "$identity"
old_receipt=$gate_receipt
gate_finish interrupted null '' 'old interruption awaiting publication'
gate_begin "$identity"
printf 'passed\n' >"$gate_attempt_dir/build.log"
gate_finish success 0 "$gate_attempt_dir/build.log"
gate_publish
before=$(wc -l <"$scratch/published.jsonl")
gate_recover
[[ "$(wc -l <"$scratch/published.jsonl")" == "$before" ]]
jq -e '.publication.superseded_by!=null and .outcome=="interrupted"' "$old_receipt" >/dev/null
printf 'PASS older outbox items never overwrite a newer accepted result\n'

exec 6>&-
export HOME_DIR owner repo sha SLOT MARKER
lock_key="acme-interrupted-$sha"
bash -s -- "$script_dir/pr-gate-state.sh" "$identity" "$lock_key" "$scratch" <<'CHILD' &
set -euo pipefail
source "$1"
gate_lock "$3"
gate_begin "$2"
sleep 30 &
worker=$!
printf '%s\n%s\n' "$BASHPID" "$worker" >"$4/worker-pids"
wait "$worker"
CHILD
parent=$!
for _ in $(seq 1 100); do [[ -f "$scratch/worker-pids" ]] && break; sleep 0.02; done
[[ -f "$scratch/worker-pids" ]]
worker=$(tail -n 1 "$scratch/worker-pids")
if (gate_lock "$lock_key"); then exit 1; fi
kill -KILL "$parent"
wait "$parent" 2>/dev/null || true
if (gate_lock "$lock_key"); then exit 1; fi
kill -TERM "$worker"
for _ in $(seq 1 100); do
  if gate_lock "$lock_key"; then break; fi
  sleep 0.02
done
[[ "$gate_key_dir" == "$HOME_DIR/attempts/$lock_key" ]]
gate_recover
jq -e '.terminal and .outcome=="interrupted" and .exit_code==null and .publication.required_status' \
  "$gate_key_dir/last-result.json" >/dev/null
printf 'PASS duplicate dispatch, killed parent, surviving worker and recovered claim\n'

gate_begin "$identity"
timeout_exit=0
timeout 0.05s sleep 2 >"$gate_attempt_dir/build.log" 2>&1 || timeout_exit=$?
[[ "$timeout_exit" == 124 ]]
gate_finish timed_out "$timeout_exit" "$gate_attempt_dir/build.log"
gate_publish
jq -e '.outcome=="timed_out" and .exit_code==124 and .terminal' "$gate_receipt" >/dev/null
printf 'PASS actual timeout is recorded with its process exit\n'
exec 6>&-

# Exercise the exact sync_repo function from the runner with real Git objects.
BASE=https://forge.example.test
run="$scratch/tree" mirrors="$scratch/mirrors"
mkdir -p "$run" "$mirrors"
git init -q --initial-branch=main "$scratch/source"
git -C "$scratch/source" config user.name 'Fixture'
git -C "$scratch/source" config user.email 'fixture@example.invalid'
printf 'source\n' >"$scratch/source/data"
git -C "$scratch/source" add data
git -C "$scratch/source" commit -qm fixture
git clone --quiet --bare --no-local "$scratch/source" "$mirrors/fixture.git"
# sync_repo points the tree's hooks path at the runner-owned hook that refuses a push.
HOOKS="$scratch/hooks"; mkdir -p "$HOOKS"
printf '#!/bin/sh\nprintf "pr-gate-runner: a gate never pushes\\n" >&2\nexit 1\n' >"$HOOKS/pre-push"
chmod 0755 "$HOOKS/pre-push"
sed -n '/^sync_repo() {/,/^}/p' "$script_dir/pr-gate-runner.sh" >"$scratch/sync.sh"
# shellcheck source=/dev/null
source "$scratch/sync.sh"
sync_repo fixture mirror/main
for owner in acme gate-a; do
  git -C "$run/fixture" config --add remote.origin.url /wrong/mirror
  git -C "$run/fixture" config --add remote.origin.pushurl /wrong/push
  sync_repo fixture mirror/main
  [[ "$(git -C "$run/fixture" remote get-url origin)" == "$BASE/git/$owner/fixture.git" ]]
  # Both URLs are the hosted repository: some repositories' hosted-source-authority tests require the
  # push URL to be canonical, and a refusing one failed every one of their gates. A push is refused by
  # the runner-owned hook instead, which those tests do not inspect.
  [[ "$(git -C "$run/fixture" remote get-url --push origin)" == "$BASE/git/$owner/fixture.git" ]]
  # ... and it answers that because no pushurl key exists, which some repositories refuse outright.
  [[ -z "$(git -C "$run/fixture" config --get-all remote.origin.pushurl || true)" ]]
  [[ "$(git -C "$run/fixture" config --get core.hooksPath)" == "$HOOKS" ]]
  if git -C "$run/fixture" push --dry-run cache-mirror HEAD:refs/heads/probe 2>"$scratch/push.err"; then
    printf 'the runner pre-push hook allowed a push\n' >&2
    exit 1
  fi
  grep -q 'a gate never pushes' "$scratch/push.err"
  [[ "$(git -C "$run/fixture" remote get-url --all origin | wc -l)" == 1 ]]
  [[ "$(git -C "$run/fixture" remote get-url --push --all origin | wc -l)" == 1 ]]
  [[ "$(git -C "$run/fixture" remote get-url cache-mirror)" == "$mirrors/fixture.git" ]]
  [[ "$(git -C "$run/fixture" rev-parse HEAD)" == "$(git -C "$scratch/source" rev-parse HEAD)" ]]
done
printf 'PASS hosted fetch/push authority for both families; separate cache mirror\n'

# A slot directory with a .git but no commits is not an input. It used to end the whole tick with
# exit 128 (git's fatal for rev-parse HEAD leaving through an unguarded caller), which stopped the
# fleet completely on 2026-09-17.
inputs_probe="$scratch/inputs-probe"
mkdir -p "$inputs_probe/tree/empty" "$inputs_probe/tree/real"
git init -q --initial-branch=main "$inputs_probe/tree/empty"      # a .git with no commits at all
git init -q --initial-branch=main "$inputs_probe/tree/real"
git -C "$inputs_probe/tree/real" config user.name Fixture
git -C "$inputs_probe/tree/real" config user.email fixture@example.invalid
printf 'x\n' >"$inputs_probe/tree/real/file"
git -C "$inputs_probe/tree/real" add file
git -C "$inputs_probe/tree/real" commit -qm fixture
git -C "$inputs_probe/tree/real" remote add origin https://forge.invalid/git/acme/real.git
mkdir -p "$inputs_probe/home" "$inputs_probe/tools" "$inputs_probe/runtime" "$inputs_probe/vendor"
run="$inputs_probe/tree" repo=real recipe_name="just required" TOOLS="$inputs_probe/tools" \
  RUNTIME_TOOLS="$inputs_probe/runtime" VENDOR="$inputs_probe/vendor" HOME_DIR="$inputs_probe/home" \
  SLOT=0 SCCACHE="" GATE_RUNNER_SCRIPT="$script_dir/pr-gate-runner.sh" \
  gate_inputs "$inputs_probe/inputs.json"
jq -e '[.sources[].repository] == ["real"]' "$inputs_probe/inputs.json" >/dev/null \
  || { printf 'gate_inputs did not skip the commitless directory\n' >&2; cat "$inputs_probe/inputs.json" >&2; exit 1; }
printf 'PASS gate inputs: a directory with no commits is skipped, not fatal\n'


# A fixture or vendor tree being written by a live build must not end the gate: scratch is excluded and
# a file that vanishes between find and hash is recorded, not fatal.
hash_probe="$scratch/hash-probe"
mkdir -p "$hash_probe/.build" "$hash_probe/keep"
printf 'stable\n' >"$hash_probe/keep/artifact"
printf 'scratch\n' >"$hash_probe/.build/object.o"
printf 'partial\n' >"$hash_probe/keep/object.o.tmp"
out=$(hash_fixture_tree "$hash_probe")
grep -q 'keep/artifact' <<<"$out"
! grep -q '.build/object.o' <<<"$out" || { printf 'live build scratch was hashed as an input\n' >&2; exit 1; }
! grep -q 'object.o.tmp' <<<"$out" || { printf 'a partial file was hashed as an input\n' >&2; exit 1; }
printf 'PASS gate inputs: live build scratch is excluded from the input identity\n'

# Exact manifest identity: similarly named repositories retain their own contexts. The mapping is site
# configuration (PR_GATE_CONTEXT_OVERRIDES); with none, every repository requires <repo>/required.
[[ "$(gate_required_context gate-a hubDB)" == hubDB/required ]]
PR_GATE_CONTEXT_OVERRIDES="other/x=x/required gate-a/hubDB=hub/required"
[[ "$(gate_required_context gate-a hubDB)" == hub/required ]]
[[ "$(gate_required_context acme hubDB)" == hubDB/required ]]
[[ "$(gate_required_context gate-a hubdb)" == hubdb/required ]]
[[ "$(gate_required_context acme acme-deploy)" == acme-deploy/required ]]
# A legacy receipt must recover under the context actually used before the mapping existed.
owner=gate-a repo=hubDB
exec 6>&-
gate_lock "gate-a-hubDB-$sha"
gate_begin "$identity"
printf 'legacy actual success\n' >"$gate_attempt_dir/build.log"
gate_finish success 0 "$gate_attempt_dir/build.log"
gate_publish
jq -s -e '[.[] | select(has("context"))] | last.context=="hubDB/required"' "$scratch/published.jsonl" >/dev/null
# New admission binds the corrected context, so old successful input cannot be reused.
jq '.required_context="hub/required"' "$identity" >"$scratch/mapped-inputs.json"
gate_decision "$scratch/mapped-inputs.json" 0 "$statuses"
[[ "$gate_action" == run ]]
gate_begin "$scratch/mapped-inputs.json"
printf 'current actual success\n' >"$gate_attempt_dir/build.log"
gate_finish success 0 "$gate_attempt_dir/build.log"
publication_mode=403
if gate_publish; then exit 1; fi
publication_mode=201
gate_recover
jq -s -e '[.[] | select(has("context"))] | last.context=="hub/required"' "$scratch/published.jsonl" >/dev/null
printf 'PASS exact owner mapping, legacy recovery identity and changed-context invalidation\n'

# A failure says why on the PR, but only through a few known shapes rebuilt from identifier- or
# path-charset tokens; nothing free-form from the log is ever published (as asked in review).
cause_log="$scratch/cause.log"
cause_of() { printf '%b' "$1" >"$cause_log"; gate_failure_cause "$cause_log"; }
expect_cause() { # log-text expected
  local got; got=$(cause_of "$1")
  [[ "$got" == "$2" ]] || { printf 'cause of %q: got %q, expected %q\n' "$1" "$got" "$2" >&2; exit 1; }
}
expect_cause '   Compiling x v1\n\033[1m\033[91merror\033[0m: no matching package named `thiserror` found\nerror: recipe `required` failed' \
  'missing crate thiserror from the offline registry'
expect_cause 'error: failed to download `proc-macro2 v1.0.107`\n' 'missing crate proc-macro2 v1.0.107 from the offline registry'
expect_cause "thread 'tests::live_authority_manifest_validates' (987211) panicked at src/tests.rs:229:55:\n" \
  'test panicked: tests::live_authority_manifest_validates at src/tests.rs:229'
expect_cause "thread 'web::t' (1) panicked at /home/gate/gate-runner/tree-gate-a-slot2/gate-deploy/crates/a.rs:50:5:\n" \
  'test panicked: web::t at gate-deploy/crates/a.rs:50'
expect_cause 'error[E0308]: mismatched types\n' 'compile error E0308'
expect_cause '[ci] FAILED STEP (exit 1): bash scripts/validate-family.sh\n' 'step failed (exit 1): scripts/validate-family.sh'
expect_cause 'running 3 tests\ntest result: FAILED. 2 passed; 1 failed\n' 'tests failed'
# Unrecognised, absolute, or secret-carrying lines publish nothing at all.
key_header="-----BEGIN OPENSSH ""PRIVATE KEY-----"
# Built at run time, so no token-shaped literal sits in the repository text.
gh_token="gh""p_ABCDEFGHIJKLMNOPQRSTUV0123"
secrets=(jpat_0123456789abcdefSECRET "$gh_token" hunter2secretvalue userpass0123 "$key_header")
for line in \
  'error: auth failed for Authorization: Bearer jpat_0123456789abcdefSECRET' \
  'error: push to https://runner-bot:userpass0123@git.example.invalid/x.git refused' \
  'error: config has password=hunter2secretvalue in it' \
  "thread '$gh_token x' (1) panicked at src/a.rs:1:1:" \
  "thread 't' (1) panicked at /etc/secret/hunter2secretvalue.rs:1:1:" \
  "$key_header b3BlbnNzaC1rZXktdjEAAAAA" \
  'step one'; do
  expect_cause "$line\nerror: recipe \`required\` failed on line 1 with exit code 1\n" ''
  gate_begin "$identity"
  cp "$cause_log" "$gate_attempt_dir/build.log"
  gate_finish failure 1 "$gate_attempt_dir/build.log"
  gate_publish
done
tail -n 14 "$scratch/published.jsonl" >"$scratch/published-tail.jsonl"
for secret in "${secrets[@]}"; do
  if grep -qF -- "$secret" "$scratch/published-tail.jsonl"; then
    printf 'a secret-shaped value reached a published payload: %s\n' "$secret" >&2; exit 1
  fi
done
if grep -q 'cause:' "$scratch/published-tail.jsonl"; then printf 'an unrecognised line produced a cause\n' >&2; exit 1; fi
if jq -e 'select(.output) | .output | has("text")' "$scratch/published-tail.jsonl" >/dev/null; then
  printf 'a raw log excerpt was published\n' >&2; exit 1
fi
exec 6>&-
printf 'PASS failure cause: known shapes only, allowlisted tokens, nothing else from the log is published\n'

# A slot tree holds exactly the gate's family and repository: a repository synced for an earlier gate
# made the same head fingerprint differently on every slot (12 passes in an hour, 2026-09-18).
strays="$scratch/strays"
for n in keep-a keep-b stray-x stray-y; do mkdir -p "$strays/tree/$n/.git"; done
mkdir -p "$strays/tree/not-a-repo" "$strays/detached/stray-x/old-copy"
moved=$(gate_detach_strays "$strays/tree" "$strays/detached" keep-a keep-b | sort | tr '\n' ' ')
[[ "$moved" == 'stray-x stray-y ' ]] || { printf 'moved: %s\n' "$moved" >&2; exit 1; }
[[ -d "$strays/tree/keep-a/.git" && -d "$strays/tree/keep-b/.git" && -d "$strays/tree/not-a-repo" ]]
[[ ! -e "$strays/tree/stray-x" && -d "$strays/detached/stray-x/.git" && ! -e "$strays/detached/stray-x/old-copy" ]]
printf 'PASS exact tree: strays move out (replacing an older copy), family and non-checkouts stay\n'

# Re-verifying a head keeps this runner's own newest success instead of posting `pending` over it.
owner=jeryu repo=jeryu-web MARKER=pr-gate-runner@test
snap="$scratch/snap.json"
own_success() { printf '{"statuses":[%s]}' "$1" >"$snap"; gate_newest_is_own_success "$snap"; }
ok='{"context":"jeryu-web/required","state":"success","description":"pr-gate-runner@test operator-unsealed success; exit 0","created_at":"2026-09-18T14:00:00Z"}'
own_success "$ok" || { printf 'own newest success not recognised\n' >&2; exit 1; }
if own_success "$ok,"'{"context":"jeryu-web/required","state":"pending","description":"pr-gate-runner@test running","created_at":"2026-09-18T14:01:00Z"}'; then
  printf 'a newer pending was ignored\n' >&2; exit 1; fi
if own_success '{"context":"jeryu-web/required","state":"success","description":"manual by someone","created_at":"2026-09-18T14:00:00Z"}'; then
  printf 'another poster'"'"'s success was treated as ours\n' >&2; exit 1; fi
if own_success '{"context":"jeryu-web/required","state":"failure","description":"pr-gate-runner@test operator-unsealed failure","created_at":"2026-09-18T14:00:00Z"}'; then
  printf 'a failure was treated as green\n' >&2; exit 1; fi
if own_success '{"context":"other/required","state":"success","description":"pr-gate-runner@test ok","created_at":"2026-09-18T14:00:00Z"}'; then
  printf 'another context counted\n' >&2; exit 1; fi
if own_success ''; then printf 'no status counted as green\n' >&2; exit 1; fi
printf 'PASS keep green: only this runner'"'"'s newest success on the exact context suppresses pending\n'

# A runner installed mid-gate must not change the gate's inputs: the running code is what was hashed at
# start (a gate once published "inputs_changed" as an error for a passing recipe during an install).
self_probe="$scratch/self-probe"
mkdir -p "$self_probe"
cp "$script_dir/pr-gate-runner.sh" "$self_probe/pr-gate-runner.sh"
GATE_SELF_SHA256=$(sha256sum "$script_dir/pr-gate-state.sh" "$self_probe/pr-gate-runner.sh")
before=$(printf '%s' "$GATE_SELF_SHA256" | grep -o '^[0-9a-f]*' | tail -1)
printf '# installed mid-gate\n' >>"$self_probe/pr-gate-runner.sh"
run="$inputs_probe/tree" repo=real recipe_name="just required" TOOLS="$inputs_probe/tools" \
  RUNTIME_TOOLS="$inputs_probe/runtime" VENDOR="$inputs_probe/vendor" HOME_DIR="$inputs_probe/home" \
  SLOT=0 SCCACHE="" GATE_RUNNER_SCRIPT="$self_probe/pr-gate-runner.sh" GATE_SELF_SHA256="$GATE_SELF_SHA256" \
  gate_inputs "$self_probe/inputs.json"
jq -r .tools "$self_probe/inputs.json" | grep -q "^$before " \
  || { printf 'gate inputs hashed the runner on disk, not the running copy\n' >&2; exit 1; }
unset GATE_SELF_SHA256
run="$inputs_probe/tree" repo=real recipe_name="just required" TOOLS="$inputs_probe/tools" \
  RUNTIME_TOOLS="$inputs_probe/runtime" VENDOR="$inputs_probe/vendor" HOME_DIR="$inputs_probe/home" \
  SLOT=0 SCCACHE="" GATE_RUNNER_SCRIPT="$self_probe/pr-gate-runner.sh" \
  gate_inputs "$self_probe/inputs-disk.json"
! jq -r .tools "$self_probe/inputs-disk.json" | grep -q "^$before " \
  || { printf 'the on-disk fallback did not hash the file on disk\n' >&2; exit 1; }
printf 'PASS self hash: a runner installed mid-gate does not change the running gate'"'"'s inputs\n'

mirrors="$scratch/mirrors"
for n in alpha beta; do
  git init -q --bare "$mirrors/$n.git"
  git -C "$mirrors/$n.git" -c user.name=F -c user.email=f@example.invalid commit-tree -m "$n" \
    "$(git -C "$mirrors/$n.git" mktree </dev/null)" >"$scratch/$n.sha"
  git -C "$mirrors/$n.git" update-ref refs/heads/main "$(cat "$scratch/$n.sha")"
done
record="$scratch/mains"
gate_record_mains "$record" "$mirrors" alpha beta gone
[[ "$(cat "$record")" == "alpha $(cat "$scratch/alpha.sha")"$'\n'"beta $(cat "$scratch/beta.sha")" ]]
touch -d '-1 hour' "$record"
gate_record_mains "$record" "$mirrors" beta alpha
! gate_regate_settling "$record" 90
gate_regate_settling "$record" 7200
git -C "$mirrors/beta.git" -c user.name=F -c user.email=f@example.invalid commit-tree -m moved \
  -p "$(cat "$scratch/beta.sha")" "$(git -C "$mirrors/beta.git" mktree </dev/null)" >"$scratch/beta.sha"
git -C "$mirrors/beta.git" update-ref refs/heads/main "$(cat "$scratch/beta.sha")"
gate_record_mains "$record" "$mirrors" alpha beta
gate_regate_settling "$record" 90
! gate_regate_settling "$record" 90 "$(( $(date +%s) + 91 ))"
! gate_regate_settling "$scratch/no-record" 90
printf 'PASS re-gate coalescing: unchanged mains keep the record, a moved main opens the settle window\n'
