#!/usr/bin/env bash
set -euo pipefail
# A gate may run this suite inside a pr-gate-runner whose environment reaches the recipe. Its
# GATE_RUNNER_*/JERYU_*/PR_GATE_* variables would then steer the code under test. Start clean.
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
# shellcheck source=ops/pr-gate/bin/pr-gate-state.sh
source "$script_dir/pr-gate-state.sh"
# shellcheck source=ops/pr-gate/bin/pr-gate-progress.sh
source "$script_dir/pr-gate-progress.sh"
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
  # The same line printed as a step (the head's recipe chooses what it prints), beside one step that
  # protected main's gate sources name: only that one may be published by name.
  printf '[pr-ci] jankurai pin drift check\n==> %s\n' "$line" >>"$gate_attempt_dir/build.log"
  printf 'echo "[pr-ci] jankurai pin drift check" >&2\n' >"$gate_attempt_dir/step-sources"
  gate_steps_record "$gate_attempt_dir/build.log" "$gate_attempt_dir/steps.tsv" 100 || true
  printf '130\n' >"$gate_attempt_dir/steps.end"
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
# The checklist was published, naming main's step and only numbering the head's own lines.
jq -se '[.[] | select(.output) | .output.summary] | length == 7 and all(test("^✓ jankurai pin drift check · 0s\n✗ step 2 · 30s\n"))' \
  "$scratch/published-tail.jsonl" >/dev/null \
  || { printf 'the published checklist is not main-named steps plus numbered ones\n' >&2; cat "$scratch/published-tail.jsonl" >&2; exit 1; }
if jq -e 'select(.output) | .output | has("text")' "$scratch/published-tail.jsonl" >/dev/null; then
  printf 'a raw log excerpt was published\n' >&2; exit 1
fi
exec 6>&-
printf 'PASS failure cause and step checklist: known shapes, protected-main step names only; nothing else from the log is published\n'

# Output cleanup cannot preserve a symlink to somebody else's build or evidence tree.
cache_target="$scratch/cache-target"
mkdir -p "$cache_target/build-cache" "$scratch/cache-outside"
touch "$cache_target/build-cache/artifact" "$cache_target/report.json" "$scratch/cache-outside/evidence"
gate_prepare_target "$cache_target" 1
[[ -f "$cache_target/build-cache/artifact" && ! -e "$cache_target/report.json" ]]
gate_prepare_target "$cache_target" 0
[[ ! -e "$cache_target/build-cache" ]]
ln -s "$scratch/cache-outside" "$cache_target/build-cache"
if gate_prepare_target "$cache_target" 1; then printf 'symlinked cache accepted\n' >&2; exit 1; fi
[[ -f "$scratch/cache-outside/evidence" ]]
gate_prepare_target "$cache_target" 0
[[ -f "$scratch/cache-outside/evidence" && ! -e "$cache_target/build-cache" ]]
printf 'PASS ordinary build retention keeps only its physical directory and refuses cache symlinks\n'

cache_source="$scratch/cache-source"
git init -q --initial-branch=main "$cache_source"
git -C "$cache_source" config user.name Fixture
git -C "$cache_source" config user.email fixture@example.invalid
printf 'original recipe\n' >"$cache_source/Justfile"
git -C "$cache_source" add Justfile
git -C "$cache_source" commit -qm recipe
printf '%s\n' '{"tools":"compiler-a","versions":"rustc 1.95.0","execution_kind":"operator-unsealed","sources":[{"repository":"fixture","head":"a","tree":"b","cargo_lock_sha256":"lock"},{"repository":"tool","head":"c","tree":"d"}]}' >"$scratch/cache-inputs.json"
cache_key=$(gate_build_cache_key "$scratch/cache-inputs.json" fixture "$cache_source")
# What cargo checks for itself never moves the key: the gated head, a sibling's main, the lock, and
# the recipe files.
for change in '.sources[0].head="changed" | .sources[0].tree="changed"' '.sources[0].cargo_lock_sha256="new-lock"' '.sources[1].head="new-sibling"'; do
  jq "$change" "$scratch/cache-inputs.json" >"$scratch/cache-changed.json"
  [[ "$cache_key" == "$(gate_build_cache_key "$scratch/cache-changed.json" fixture "$cache_source")" ]]
done
printf 'changed recipe\n' >"$cache_source/Justfile"
git -C "$cache_source" commit -qam changed-recipe
[[ "$cache_key" == "$(gate_build_cache_key "$scratch/cache-inputs.json" fixture "$cache_source")" ]]
# What it cannot see always does: compiler and tool bytes, reported versions, the execution kind.
for change in '.tools="compiler-b"' '.versions="rustc 1.96.0"' '.execution_kind="contributed-sandbox"'; do
  jq "$change" "$scratch/cache-inputs.json" >"$scratch/cache-changed.json"
  [[ "$cache_key" != "$(gate_build_cache_key "$scratch/cache-changed.json" fixture "$cache_source")" ]]
done
printf 'PASS cache identity binds compiler, tool and host bytes only; sources, siblings, lock and recipe are cargo'"'"'s to check\n'

# The shared store: a key match seeds a physical copy, a mismatch or an empty store builds cold, a
# publish replaces the current version, and pruning keeps any version a reader is still copying.
store="$scratch/golden/acme/fixture"
key_a=$(printf a | sha256sum | cut -c1-64) key_b=$(printf b | sha256sum | cut -c1-64)
seed_into="$scratch/golden-slot/build-cache"
mkdir -p "$seed_into"
if gate_golden_seed "$store" "$key_a" "$seed_into" >/dev/null; then printf 'an empty store seeded a cache\n' >&2; exit 1; fi
mkdir -p "$scratch/golden-build/one/debug/deps" "$scratch/golden-build/one/debug/.fingerprint/crate-1"
printf 'one\n' >"$scratch/golden-build/one/artifact"
for n in $(seq 1 200); do printf '%s\n' "$n" >"$scratch/golden-build/one/debug/deps/lib$n.rlib"; done
printf 'fp\n' >"$scratch/golden-build/one/debug/.fingerprint/crate-1/lib-crate"
ln -s deps/lib1.rlib "$scratch/golden-build/one/debug/latest"
touch -d '2026-01-02 03:04:05' "$scratch/golden-build/one/debug/deps/lib7.rlib" "$scratch/golden-build/one/debug/.fingerprint/crate-1/lib-crate"
gate_golden_publish "$store" "$key_a" "$scratch/golden-build/one" v1
[[ ! -e "$scratch/golden-build/one" && "$(cat "$store/current")" == "v1 $key_a" ]]
[[ "$(gate_golden_seed "$store" "$key_a" "$seed_into")" == v1 && -f "$seed_into/artifact" && ! -L "$seed_into" ]]
# Every file, every mtime (cargo's freshness), and symlinks as symlinks.
[[ "$(find "$seed_into" -type f | wc -l)" == 202 && -L "$seed_into/debug/latest" \
   && "$(readlink "$seed_into/debug/latest")" == deps/lib1.rlib ]]
for f in debug/deps/lib7.rlib debug/.fingerprint/crate-1/lib-crate debug/deps/lib150.rlib; do
  [[ "$(stat -c %Y "$seed_into/$f")" == "$(stat -c %Y "$store/versions/v1/$f")" ]] \
    || { printf 'seeding changed the mtime of %s\n' "$f" >&2; exit 1; }
done
# The copy is the slot's own: writing to it never reaches the published version.
printf 'slot-only\n' >>"$seed_into/artifact"
[[ "$(cat "$store/versions/v1/artifact")" == one ]]
if gate_golden_seed "$store" "$key_b" "$seed_into" >/dev/null; then printf 'a different key seeded a cache\n' >&2; exit 1; fi
# A reader holding v1 keeps it through the next publish; once released, the next publish prunes it.
exec {reader}>>"$store/versions/v1.lock"; flock -s "$reader"
mkdir -p "$scratch/golden-build/two"; printf 'two\n' >"$scratch/golden-build/two/artifact"
gate_golden_publish "$store" "$key_b" "$scratch/golden-build/two" v2
[[ "$(cat "$store/current")" == "v2 $key_b" && -d "$store/versions/v1" ]]
exec {reader}>&-
mkdir -p "$scratch/golden-build/three"
gate_golden_publish "$store" "$key_b" "$scratch/golden-build/three" v3
[[ ! -e "$store/versions/v1" && ! -e "$store/versions/v2" && -d "$store/versions/v3" ]]
# A symlink is never published, and a version name is never reused.
ln -s "$scratch/golden-build/elsewhere" "$scratch/golden-build/link"
if gate_golden_publish "$store" "$key_b" "$scratch/golden-build/link" v4; then printf 'a symlinked cache was published\n' >&2; exit 1; fi
mkdir -p "$scratch/golden-build/again"
if gate_golden_publish "$store" "$key_b" "$scratch/golden-build/again" v3; then printf 'a version was overwritten\n' >&2; exit 1; fi
[[ "$(cat "$store/current")" == "v3 $key_b" ]]
printf 'PASS shared build cache: key-matched physical seeds, atomic publish, pruning spares versions being copied\n'

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

# Evidence mirrors: a bare <name>.git beside the family, refreshed with main and tags, left alone by
# the stray detach; an unreachable or malformed source is reported and never fatal.
ev="$scratch/evidence"
mkdir -p "$ev/forge/git/labs" "$ev/tree" "$ev/work"
git init --quiet --bare "$ev/forge/git/labs/proof.git"
git -C "$ev/work" init --quiet -b main
git -C "$ev/work" -c user.name=t -c user.email=t@t commit --quiet --allow-empty -m one
git -C "$ev/work" tag release-1
git -C "$ev/work" push --quiet "$ev/forge/git/labs/proof.git" main release-1
out=$(gate_mirror_evidence "$ev/tree" "$ev/forge" labs/proof)
[[ -z "$out" && -d "$ev/tree/proof.git" && ! -e "$ev/tree/proof.git/.git" ]]
git -C "$ev/work" -c user.name=t -c user.email=t@t commit --quiet --allow-empty -m two
git -C "$ev/work" tag release-2
git -C "$ev/work" push --quiet "$ev/forge/git/labs/proof.git" main release-2
gate_mirror_evidence "$ev/tree" "$ev/forge" labs/proof >/dev/null
[[ "$(git -C "$ev/tree/proof.git" rev-parse main)" == "$(git -C "$ev/work" rev-parse HEAD)" ]]
git -C "$ev/tree/proof.git" rev-parse --verify --quiet refs/tags/release-2 >/dev/null
[[ -z "$(gate_detach_strays "$ev/tree" "$ev/detached")" && -d "$ev/tree/proof.git" ]]
out=$(gate_mirror_evidence "$ev/tree" "$ev/forge" labs/missing 'bad name')
[[ "$out" == *"labs/missing: cannot mirror"* && "$out" == *"bad name: not owner/name"* && ! -e "$ev/tree/missing.git" ]]
[[ "$(PR_GATE_EVIDENCE_REPOS='acme=labs/proof other=labs/x acme=labs/y' gate_evidence_for acme | tr '\n' ' ')" == 'labs/proof labs/y ' ]]
[[ -z "$(PR_GATE_EVIDENCE_REPOS='other=labs/x' gate_evidence_for acme)" && -z "$(gate_evidence_for acme)" ]]
printf 'PASS evidence mirrors: per tree owner, bare beside the family, refreshed with tags, kept by the detach, never fatal\n'

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

# A head that changes the gate it is judged by. The set is the recipe entry point, the CI scripts it
# calls and the jankurai and policy files those read -- not ordinary tests, and not documentation.
self_gate="$scratch/self-gate"
git init -q --initial-branch=main "$self_gate"
git -C "$self_gate" config user.name Fixture
git -C "$self_gate" config user.email fixture@example.invalid
mkdir -p "$self_gate/ops/ci" "$self_gate/crates/thing/tests" "$self_gate/docs" "$self_gate/agent" "$self_gate/policies"
printf 'base\n' >"$self_gate/ops/ci/check.sh"
printf 'base\n' >"$self_gate/Justfile"
printf 'base\n' >"$self_gate/agent/jankurai-gate.toml"
printf 'base\n' >"$self_gate/policies/trust-tiers.toml"
printf 'base\n' >"$self_gate/crates/thing/tests/it.rs"
printf 'base\n' >"$self_gate/docs/jankurai-gate.md"
printf 'base\n' >"$self_gate/crates/thing/src.rs"
git -C "$self_gate" add .
git -C "$self_gate" commit -qm base
git -C "$self_gate" checkout -q -b head
expect_definition_paths() { # expected
  local got; got=$(gate_definition_paths "$self_gate" main head | paste -sd' ')
  [[ "$got" == "$1" ]] || { printf 'gate-defining paths: got %q, expected %q\n' "$got" "$1" >&2; exit 1; }
}
for file in crates/thing/tests/it.rs docs/jankurai-gate.md crates/thing/src.rs; do
  printf 'changed\n' >"$self_gate/$file"
done
git -C "$self_gate" commit -qam 'ordinary work on tests, docs and code'
expect_definition_paths ''
for file in ops/ci/check.sh Justfile agent/jankurai-gate.toml policies/trust-tiers.toml; do
  printf 'changed\n' >"$self_gate/$file"
done
printf 'added\n' >"$self_gate/ops/ci/new-step.sh"
git -C "$self_gate" add ops/ci/new-step.sh
git -C "$self_gate" commit -qam 'rewrite the gate'
expect_definition_paths 'Justfile agent/jankurai-gate.toml ops/ci/check.sh ops/ci/new-step.sh policies/trust-tiers.toml'
printf 'PASS gate-defining paths: the recipe, its CI scripts and the policy files it reads, not tests or docs\n'

# The annotation names them, bounded, and only paths of a shape this runner recognises.
note_receipt="$scratch/note-receipt.json"
note_of() { printf '%s\n' "$1" >"$note_receipt"; gate_self_modification_note "$note_receipt"; }
[[ -z "$(note_of '{}')" && -z "$(note_of '{"gate_definition_paths":[]}')" ]]
[[ -z "$(note_of '{"gate_definition_paths":["ops/ci/$(whoami).sh"]}')" ]]
note=$(note_of '{"gate_definition_paths":["Justfile","ops/ci/check.sh"]}')
[[ "$note" == 'Needs a human: this head changes the gate that judges it (Justfile, ops/ci/check.sh). The gate ran this head'"'"'s own recipe, so the conclusion above is the head reporting on itself. Read the gate change against protected main before trusting it.' ]] \
  || { printf 'annotation: %q\n' "$note" >&2; exit 1; }
many=$(jq -nc '{gate_definition_paths:[range(0;13) | "ops/ci/step-\(.).sh"]}')
note=$(note_of "$many")
[[ "$note" == *'ops/ci/step-9.sh and 3 more).'* ]] || { printf 'annotation: %q\n' "$note" >&2; exit 1; }
printf 'PASS the self-modification annotation names a bounded, recognised-shape path list\n'

# Portable input identity: the same tree, tools and runner hash the same wherever a host keeps them.
# The two "hosts" below differ only in where their tools, runtime tools and state live.
for host in a b; do
  mkdir -p "$scratch/host-$host/tools/bin" "$scratch/host-$host/runtime" "$scratch/host-$host/home"
  printf 'governed tool\n' >"$scratch/host-$host/tools/bin/auditor"
  printf 'fixture\n' >"$scratch/host-$host/runtime/data"
  run="$inputs_probe/tree" repo=real recipe_name="just required" TOOLS="$scratch/host-$host/tools" \
    RUNTIME_TOOLS="$scratch/host-$host/runtime" VENDOR="" HOME_DIR="$scratch/host-$host/home" \
    SLOT=0 SCCACHE="" GATE_RUNNER_SCRIPT="$script_dir/pr-gate-runner.sh" \
    gate_inputs "$scratch/host-$host/inputs.json"
done
cmp -s "$scratch/host-a/inputs.json" "$scratch/host-b/inputs.json" \
  || { printf 'two hosts disagree about identical inputs\n' >&2; diff "$scratch/host-a/inputs.json" "$scratch/host-b/inputs.json" >&2; exit 1; }
jq -e '.runner == "pr-gate-runner"' "$scratch/host-a/inputs.json" >/dev/null
if jq -r .tools "$scratch/host-a/inputs.json" | grep -qF -e "$scratch" -e "$HOME/"; then
  printf 'a host path reached the input identity\n' >&2; exit 1; fi
jq -r .tools "$scratch/host-a/inputs.json" | grep -q '  tools/bin/auditor$'
jq -r .tools "$scratch/host-a/inputs.json" | grep -q '  runtime-tools/data$'
printf 'changed\n' >"$scratch/host-b/tools/bin/auditor"
run="$inputs_probe/tree" repo=real recipe_name="just required" TOOLS="$scratch/host-b/tools" \
  RUNTIME_TOOLS="$scratch/host-b/runtime" VENDOR="" HOME_DIR="$scratch/host-b/home" \
  SLOT=0 SCCACHE="" GATE_RUNNER_SCRIPT="$script_dir/pr-gate-runner.sh" \
  gate_inputs "$scratch/host-b/changed.json"
[[ "$(gate_inputs_digest "$scratch/host-a/inputs.json")" != "$(gate_inputs_digest "$scratch/host-b/changed.json")" ]] \
  || { printf 'a changed governed tool kept the same identity\n' >&2; exit 1; }
printf 'PASS portable inputs: no host or path in the identity, content still bound\n'

# Escaped tree names cannot add synthetic identity rows.
mkdir -p "$scratch/escaped"
printf x >"$scratch/escaped/"$'line\nbreak'
printf y >"$scratch/escaped/back\\slash"
hash_fixture_tree "$scratch/escaped" tools >"$scratch/escaped.txt"
[[ "$(wc -l <"$scratch/escaped.txt")" == 2 ]]
grep -qF 'tools/line\nbreak' "$scratch/escaped.txt"
grep -qF 'tools/back\\slash' "$scratch/escaped.txt"
printf 'PASS fixture names escape newline/backslash without identity-row injection\n'

# Executable input trees fail closed on unreadable entries instead of sharing a constant identity.
mkdir -p "$scratch/exec-only"
printf '#!/bin/sh\nexit 0\n' >"$scratch/exec-only/helper"
chmod 0111 "$scratch/exec-only/helper"
if (( $(id -u) != 0 )); then
  if hash_fixture_tree "$scratch/exec-only" path all >"$scratch/exec-only.txt" 2>"$scratch/exec-only.err"; then
    printf 'an unreadable executable produced a reusable identity\n' >&2; exit 1
  fi
  grep -q 'cannot bind executable input' "$scratch/exec-only.err"
  mkdir -p "$scratch/exec-only/hidden"
  printf different >"$scratch/exec-only/hidden/secret-helper"
  chmod 0111 "$scratch/exec-only/hidden"
  if hash_fixture_tree "$scratch/exec-only" path all >/dev/null 2>"$scratch/exec-only.err"; then
    printf 'an unreadable directory produced a reusable identity\n' >&2; exit 1
  fi
  grep -q 'cannot walk input tree' "$scratch/exec-only.err"
  chmod 0755 "$scratch/exec-only/hidden"
else
  # Root can read mode-0111 files; an injected read failure exercises the same fail-closed branch.
  sha256sum() { return 1; }
  if hash_fixture_tree "$scratch/exec-only" path all >/dev/null 2>/dev/null; then exit 1; fi
  unset -f sha256sum
fi
chmod 0644 "$scratch/exec-only/helper"
printf 'PASS unreadable executable inputs fail closed\n'

# The site configuration binds the settings that can change a verdict, not where a host keeps things.
unset PR_GATE_CONTEXT_OVERRIDES PR_GATE_OK_TO_TEST_MAINTAINERS PR_GATE_CONTRIBUTED_LABEL
site="$scratch/site"; mkdir -p "$site"
cat >"$site/a.env" <<'ENV'
# host a
PR_GATE_FORGE_URL=https://forge.example.test
GATE_RUNNER_IDENTITY=runner-bot
JERYU_TOKEN_FILE=~/.config/a/token
PR_GATE_CHECKOUT_ROOTS="acme=src/acme"
PR_GATE_LOCK_SOURCES=git+https://forge.example.test/
GATE_RUNNER_OWNERS=acme
PATH=/ignored
ENV
cat >"$site/b.env" <<'ENV'
PR_GATE_LOCK_SOURCES='git+https://forge.example.test/'
GATE_RUNNER_OWNERS="acme globex"
PR_GATE_CHECKOUT_ROOT_PATTERN=gate-roots/{owner}
JERYU_TOKEN_FILE=/srv/b/token
  GATE_RUNNER_IDENTITY=runner-bot

PR_GATE_FORGE_URL=https://forge.example.test
GATE_RUNNER_WAKE_WAIT=30
ENV
a=$(gate_site_config_digest "$site/a.env")
[[ "$a" =~ ^[0-9a-f]{64}$ && "$a" == "$(gate_site_config_digest "$site/b.env")" ]] \
  || { printf 'host-local settings changed the site digest\n' >&2; exit 1; }
# A changed setting is put first: of repeated keys the loader keeps the first, and so does the digest.
for change in 'PR_GATE_LOCK_SOURCES=git+https://other.example.test/' 'PR_GATE_CONTEXT_OVERRIDES=acme/x=y/required' \
    'PR_GATE_DEPENDENCIES=acme/web=tool' \
    'PR_GATE_SOME_FUTURE_SETTING=1' 'PR_GATE_OK_TO_TEST_MAINTAINERS=*' 'PR_GATE_CONTRIBUTED_LABEL=outside'; do
  { printf '%s\n' "$change"; cat "$site/a.env"; } >"$site/changed.env"
  [[ "$(gate_site_config_digest "$site/changed.env")" != "$a" ]] \
    || { printf 'site digest ignored %s\n' "$change" >&2; exit 1; }
done
# ... and a repeat after the first is not in effect, so it is not an input either.
{ cat "$site/a.env"; printf 'PR_GATE_LOCK_SOURCES=git+https://other.example.test/\n'; } >"$site/repeat.env"
[[ "$(gate_site_config_digest "$site/repeat.env")" == "$a" ]] || { printf 'a shadowed repeat changed the digest\n' >&2; exit 1; }
printf 'PR_GATE_LOCK_SOURCES=x\nPR_GATE_LOCK_SOURCES=y\n' >"$site/xy.env"
printf 'PR_GATE_LOCK_SOURCES=y\nPR_GATE_LOCK_SOURCES=x\n' >"$site/yx.env"
[[ "$(gate_site_config_digest "$site/xy.env")" != "$(gate_site_config_digest "$site/yx.env")" ]] \
  || { printf 'repeated keys in another order kept the digest though the loader keeps another value\n' >&2; exit 1; }
# A setting overridden in the environment (a unit's Environment= line) is what is in effect.
[[ "$(PR_GATE_LOCK_SOURCES=git+https://other.example.test/ gate_site_config_digest "$site/a.env")" != "$a" ]] \
  || { printf 'an environment override was not an input\n' >&2; exit 1; }
[[ "$(PR_GATE_LOCK_SOURCES=git+https://forge.example.test/ gate_site_config_digest "$site/a.env")" == "$a" ]]
[[ "$(JERYU_TOKEN_FILE=/elsewhere GATE_RUNNER_SLOT=3 gate_site_config_digest "$site/a.env")" == "$a" ]]
# shellcheck disable=SC2088  # a literal "~/" value, as a site file may carry it
[[ "$(PR_GATE_SANDBOX_COMMAND="$HOME/bin/vm" gate_site_config_digest "$site/a.env")" \
   == "$(PR_GATE_SANDBOX_COMMAND="~/bin/vm" gate_site_config_digest "$site/a.env")" ]]
missing=$(gate_site_config_digest "$site/missing.env")
[[ "$missing" =~ ^[0-9a-f]{64}$ ]]
[[ "$(PR_GATE_SANDBOX_COMMAND=/vm/a gate_site_config_digest "$site/missing.env")" \
   != "$(PR_GATE_SANDBOX_COMMAND=/vm/b gate_site_config_digest "$site/missing.env")" ]]
[[ "$(PR_GATE_OK_TO_TEST_MAINTAINERS=dana gate_site_config_digest "$site/missing.env")" \
   != "$(PR_GATE_OK_TO_TEST_MAINTAINERS=mallory gate_site_config_digest "$site/missing.env")" ]]
printf 'PASS site digest: the effective settings that can change a verdict, not host-local ones, comments or order\n'

# The published required status names the inputs' digest, so another host can match it.
owner=acme repo=fixture
exec 6>&-
gate_lock "acme-fixture-$sha"
gate_begin "$scratch/host-a/inputs.json"
printf 'passed\n' >"$gate_attempt_dir/build.log"
gate_finish success 0 "$gate_attempt_dir/build.log"
gate_publish
digest=$(gate_inputs_digest "$scratch/host-a/inputs.json")
jq -s -e --arg d "$digest" '[.[] | select(has("context"))] | last.description | endswith("; inputs " + $d)' \
  "$scratch/published.jsonl" >/dev/null || { tail -2 "$scratch/published.jsonl" >&2; exit 1; }
exec 6>&-
printf 'PASS publication: the required status carries the input digest\n'

# Another host's result, read from the forge: reused or held only when this gate identity posted it from a
# pr-gate runner for exactly these inputs, and never for a retry. This host has no receipt for the head.
IDENTITY=runner-bot
forge_status() { # state description [creator]
  jq -nc --arg s "$1" --arg d "$2" --arg c "${3-runner-bot}" '{statuses:[{context:"fixture/required",state:$s,
    description:$d,created_at:"2026-10-12T00:00:00Z"} + (if $c == "" then {} else {creator:{login:$c}} end)]}' >"$scratch/forge.json"
}
expect_forge() { # want-action retry
  rm -f "$gate_key_dir/forge-deferred.json" # independent fixture decisions
  gate_decision "$scratch/host-a/inputs.json" "$2" "$scratch/forge.json"
  [[ "$gate_action" == "$1" ]] || { printf 'forge decision: got %s, expected %s\n' "$gate_action" "$1" >&2; cat "$scratch/forge.json" >&2; exit 1; }
}
gate_lock "acme-fixture-1111111111111111111111111111111111111111"
other="pr-gate-runner@node-b operator-unsealed"
forge_status success "$other success; exit 0; attempt x; log y; inputs $digest"
expect_forge reuse 0
[[ "$gate_action_source" == forge ]]
# A process restart/busy pass cannot adopt these inputs for a second look.
gate_decision "$scratch/host-a/inputs.json" 0 "$scratch/forge.json"
[[ "$gate_action" == run && "$gate_action_source" == local ]]
expect_forge run 1
forge_status failure "$other failure; exit 1; attempt x; log y; inputs $digest; cause: tests failed"
expect_forge hold 0
forge_status error "$other interrupted; exit unknown; attempt x; log none; inputs $digest"
expect_forge run 0
forge_status success "$other success; exit 0; attempt x; log y; inputs ${digest}0"
expect_forge run 0
forge_status success "$other success; exit 0; attempt x; log y; inputs $(gate_inputs_digest "$scratch/host-b/changed.json")"
expect_forge run 0
forge_status success "$other success; exit 0; attempt x; log y"
expect_forge run 0
forge_status success "$other success; exit 0; attempt x; log y; inputs $digest" ''
expect_forge run 0
forge_status success "$other success; exit 0; attempt x; log y; inputs $digest" someone-else
expect_forge run 0
forge_status success "$other success; inputs $digest; cause: text; inputs $digest"
expect_forge run 0
forge_status success "manual: inputs $digest"
expect_forge run 0
exec 6>&-
printf 'PASS forge reuse: only this identity'"'"'s runner status for exactly these inputs, never for a retry\n'

# Keep green holds for a success any host's runner posted as this identity, not for another poster's.
owner=jeryu repo=jeryu-web
own_success '{"context":"jeryu-web/required","state":"success","description":"pr-gate-runner@node-b operator-unsealed success","creator":{"login":"runner-bot"},"created_at":"2026-09-18T14:00:00Z"}' \
  || { printf 'another host'"'"'s success was not kept green\n' >&2; exit 1; }
if own_success '{"context":"jeryu-web/required","state":"success","description":"pr-gate-runner@node-b forged","creator":{"login":"mallory"},"created_at":"2026-09-18T14:00:00Z"}'; then
  printf 'a runner-shaped status from another identity was kept green\n' >&2; exit 1; fi
unset IDENTITY
printf 'PASS keep green across hosts, for this gate identity only\n'

# Everything on the recipe's PATH is an input: a user directory by content (spelled under ~/), a
# system directory by its listing plus the installed package set, and the OS, architecture and kernel.
envprobe="$HOME/.cache/pr-gate-test-$$"
mkdir -p "$envprobe/bin"
trap 'rm -rf -- "$scratch" "$envprobe"' EXIT
printf '#!/bin/sh\nexit 0\n' >"$envprobe/bin/helper"
printf old >"$envprobe/bin/reachable.tmp"
recipe_inputs() { # output
  run="$inputs_probe/tree" repo=real recipe_name="just required" TOOLS="$scratch/host-a/tools" \
    RUNTIME_TOOLS="$scratch/host-a/runtime" VENDOR="" HOME_DIR="$scratch/host-a/home" \
    RECIPE_PATH="$scratch/host-a/tools:$envprobe/bin:/usr/bin" \
    SLOT=0 SCCACHE="" GATE_RUNNER_SCRIPT="$script_dir/pr-gate-runner.sh" gate_inputs "$1"
}
recipe_inputs "$scratch/env-1.json"
tools=$(jq -r .tools "$scratch/env-1.json")
grep -q "  path:~/.cache/pr-gate-test-$$/bin/helper$" <<<"$tools" \
  || { printf 'a user PATH directory was not bound by content under ~/\n' >&2; printf '%s\n' "$tools" >&2; exit 1; }
for line in '  path:/usr/bin \(listing\)$' '  system-packages$' '^os  ' '^arch  ' '^kernel  '; do
  grep -qE "$line" <<<"$tools" || { printf 'missing identity line %s\n' "$line" >&2; exit 1; }
done
! grep -qF -e "$HOME/" -e "$envprobe" <<<"$tools" || { printf 'a home path reached the identity\n' >&2; exit 1; }
printf '#!/bin/sh\nexit 1\n' >"$envprobe/bin/helper"
recipe_inputs "$scratch/env-2.json"
[[ "$(gate_inputs_digest "$scratch/env-1.json")" != "$(gate_inputs_digest "$scratch/env-2.json")" ]] \
  || { printf 'a changed executable on the recipe PATH kept the same identity\n' >&2; exit 1; }
printf changed >"$envprobe/bin/reachable.tmp"
recipe_inputs "$scratch/env-3.json"
[[ "$(gate_inputs_digest "$scratch/env-2.json")" != "$(gate_inputs_digest "$scratch/env-3.json")" ]]
if gate_inputs_digest "$scratch/no-such-inputs.json" 2>/dev/null; then printf 'digest of nothing\n' >&2; exit 1; fi
printf '[]\n' >"$scratch/not-inputs.json"
if gate_inputs_digest "$scratch/not-inputs.json" 2>/dev/null; then printf 'digest of a non-object\n' >&2; exit 1; fi
printf 'PASS recipe PATH: every directory the recipe can execute from is an input; no digest of nothing\n'

# Host enumeration errors must not become an empty digest that other hosts can reuse.
(
  find() { [[ "$1" != /usr/bin ]] || return 7; command find "$@"; }
  if RECIPE_PATH=/usr/bin TOOLS="" GATE_BOUND_RUSTC="" gate_host_environment >"$scratch/system-enum.txt" 2>"$scratch/system-enum.err"; then
    printf 'a failed system enumeration was accepted\n' >&2; exit 1
  fi
  ! grep -q 'path:/usr/bin' "$scratch/system-enum.txt"
  grep -q 'cannot enumerate system PATH' "$scratch/system-enum.err"
)
mkdir -p "$envprobe/toolchain/bin"
printf '#!/bin/sh\n' >"$envprobe/toolchain/bin/rustc"
(
  env() { [[ " $* " != *' component list '* ]] || return 7; command env "$@"; }
  if RECIPE_PATH="" GATE_BOUND_RUSTC="$envprobe/toolchain/bin/rustc" gate_host_environment >"$scratch/components-enum.txt" 2>"$scratch/components-enum.err"; then
    printf 'a failed component enumeration was accepted\n' >&2; exit 1
  fi
  ! grep -q 'toolchain-components' "$scratch/components-enum.txt"
  grep -q 'cannot enumerate installed toolchain' "$scratch/components-enum.err"
)
[[ "$(gate_python_distribution_digest "$scratch/missing-python" "$scratch/also-missing-python")" == "$(sha256sum </dev/null | cut -c1-64)" ]]
mkdir -p "$scratch/python-probe/site-packages/present-1.dist-info"
before_python=$(gate_python_distribution_digest "$scratch/python-probe")
[[ "$before_python" != "$(sha256sum </dev/null | cut -c1-64)" ]]
(
  find() { return 7; }
  if gate_python_distribution_digest "$scratch/python-probe" >"$scratch/python-enum.txt" 2>"$scratch/python-enum.err"; then
    printf 'a failed Python enumeration was accepted\n' >&2; exit 1
  fi
  [[ ! -s "$scratch/python-enum.txt" ]]
  grep -q 'cannot enumerate Python' "$scratch/python-enum.err"
)
if (( $(id -u) != 0 )); then
  mkdir -p "$scratch/python-hidden"
  chmod 0111 "$scratch/python-hidden"
  if gate_python_distribution_digest "$scratch/python-hidden" >"$scratch/python-hidden.txt" 2>/dev/null; then
    printf 'an unreadable Python root was accepted\n' >&2; exit 1
  fi
  [[ ! -s "$scratch/python-hidden.txt" ]]
  chmod 0755 "$scratch/python-hidden"
fi
printf 'PASS system/component/Python enumeration errors fail closed; absent Python roots are an empty set\n'

# A contribution binds sandbox implementation bytes and host custody, including in cheap input reuse.
printf '#!/bin/sh\nexit 0\n' >"$envprobe/sandbox"
GATE_SANDBOX=1 SANDBOX_COMMAND="$envprobe/sandbox" recipe_inputs "$scratch/sandbox-1.json"
jq -r .tools "$scratch/sandbox-1.json" | grep -q '^sandbox-host  '
printf '#!/bin/sh\nexit 1\n' >"$envprobe/sandbox"
GATE_SANDBOX=1 SANDBOX_COMMAND="$envprobe/sandbox" recipe_inputs "$scratch/sandbox-2.json"
[[ "$(gate_inputs_digest "$scratch/sandbox-1.json")" != "$(gate_inputs_digest "$scratch/sandbox-2.json")" ]]
printf 'PASS sandbox executable bytes and host custody are bound\n'

# Re-proving an adopted head turns forge reuse off; a newer success of this identity for the same inputs
# confirms this host's own verified receipt instead of superseding it.
owner=acme repo=fixture IDENTITY=runner-bot MARKER=pr-gate-runner@node-a
gate_lock "acme-fixture-2222222222222222222222222222222222222222"
forge_status success "pr-gate-runner@node-b operator-unsealed success; exit 0; attempt x; log y; inputs $digest"
GATE_FORGE_REUSE=0 gate_decision "$scratch/host-a/inputs.json" 0 "$scratch/forge.json"
[[ "$gate_action" == run ]] || { printf 'forge reuse ran while switched off\n' >&2; exit 1; }
gate_begin "$scratch/host-a/inputs.json"
printf 'passed\n' >"$gate_attempt_dir/build.log"
gate_finish success 0 "$gate_attempt_dir/build.log"
gate_publish
gate_decision "$scratch/host-a/inputs.json" 0 "$scratch/forge.json"
[[ "$gate_action" == reuse && "$gate_action_source" == local ]] \
  || { printf 'an agreeing newer success superseded verified local evidence: %s/%s\n' "$gate_action" "$gate_action_source" >&2; exit 1; }
wrong_digest="${digest%?}0"
[[ "$wrong_digest" != "$digest" ]] || wrong_digest="${digest%?}1"
forge_status success "pr-gate-runner@node-b operator-unsealed success; exit 0; attempt x; log y; inputs $wrong_digest"
gate_decision "$scratch/host-a/inputs.json" 0 "$scratch/forge.json"
[[ "$gate_action" == run ]] || { printf 'a newer success for other inputs did not supersede\n' >&2; exit 1; }
exec 6>&-
printf 'PASS adopted heads are re-proved with forge reuse off; an agreeing newer success keeps local reuse\n'

# A status without a creator is trusted for keep-green only when it is this host's own marker.
owner=jeryu repo=jeryu-web
own_success '{"context":"jeryu-web/required","state":"success","description":"pr-gate-runner@node-a operator-unsealed success","created_at":"2026-09-18T14:00:00Z"}' \
  || { printf 'own creator-less success not recognised\n' >&2; exit 1; }
if own_success '{"context":"jeryu-web/required","state":"success","description":"pr-gate-runner@node-b operator-unsealed success","created_at":"2026-09-18T14:00:00Z"}'; then
  printf 'a creator-less success naming another host was kept green\n' >&2; exit 1; fi
own_success '{"context":"jeryu-web/required","state":"success","description":"pr-gate-runner@node-a operator-unsealed success","creator":{"login":"renamed-bot"},"created_at":"2026-09-18T14:00:00Z"}' \
  || { printf 'own marker lost keep-green after identity rename\n' >&2; exit 1; }
printf 'PASS keep green without a creator: this host'"'"'s own marker only\n'

# A forge that shortens the description drops the digest; the runner says so instead of failing silently.
owner=acme repo=fixture
gate_lock "acme-fixture-3333333333333333333333333333333333333333"
api() { code=201; export body='{"id":"short","description":"pr-gate-runner@node-a operator-unsealed success; exit 0; attempt"}'; }
gate_begin "$scratch/host-a/inputs.json"
printf 'passed\n' >"$gate_attempt_dir/build.log"
gate_finish success 0 "$gate_attempt_dir/build.log"
gate_publish 2>"$scratch/short.err"
grep -q 'did not keep the inputs digest' "$scratch/short.err" || { printf 'a dropped digest was silent\n' >&2; exit 1; }
exec 6>&-
unset IDENTITY
printf 'PASS a forge that drops the inputs digest is reported\n'
