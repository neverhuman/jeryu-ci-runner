#!/usr/bin/env bash
# Offline tests of ops/ci/proof_guards.sh, and tripwires over the proof lane's
# wiring. The history guard runs against real throwaway git repositories served
# over file:// (no forge, no network); the migration guard reads the output the
# pinned Jankurai 1.7.5 really wrote, recorded as a fixture. The wiring checks
# at the end read lines, not a shell AST: they catch the named regressions, not
# every way of writing them.
set -euo pipefail
cd "$(dirname "$0")/../../.."
source ops/ci/proof_guards.sh
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

# --- history: a depth-1 pull-request checkout, with real git ---------------
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME='proof test' GIT_AUTHOR_EMAIL=proof@example.invalid
export GIT_COMMITTER_NAME='proof test' GIT_COMMITTER_EMAIL=proof@example.invalid
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
commit() { printf '%s\n' "$2" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -q --no-gpg-sign -m "$2"; }
git init -q -b main "$fixture/work"
commit "$fixture/work" m1
fork="$(git -C "$fixture/work" rev-parse HEAD)"
git -C "$fixture/work" switch -q -c topic
commit "$fixture/work" t1; commit "$fixture/work" t2; commit "$fixture/work" t3
topic="$(git -C "$fixture/work" rev-parse HEAD)"
git -C "$fixture/work" switch -q main
commit "$fixture/work" m2
main_tip="$(git -C "$fixture/work" rev-parse HEAD)"
git clone -q --bare "$fixture/work" "$fixture/forge.git"

# A single-branch depth-1 clone of the pull-request branch, as CI checks it out.
git clone -q --depth 1 --branch topic "file://$fixture/forge.git" "$fixture/pr"
[[ "$(git -C "$fixture/pr" rev-parse --is-shallow-repository)" == true ]] ||
  fail 'the fixture checkout is not shallow'
(cd "$fixture/pr" && proof_require_history) || fail 'the history guard failed on a shallow checkout'
[[ "$(git -C "$fixture/pr" rev-parse --is-shallow-repository)" == false ]] ||
  fail 'the checkout is still shallow after the history guard'
[[ "$(git -C "$fixture/pr" rev-parse refs/remotes/origin/main)" == "$main_tip" ]] ||
  fail 'protected main was not refreshed'
[[ "$(git -C "$fixture/pr" rev-parse HEAD)" == "$topic" ]] || fail 'the head moved'
[[ "$(git -C "$fixture/pr" merge-base origin/main HEAD)" == "$fork" ]] ||
  fail 'ancestry between the head and protected main is not answerable'
[[ "$(git -C "$fixture/pr" diff --name-only "origin/main...HEAD" | tr '\n' ' ')" == 't1 t2 t3 ' ]] ||
  fail 'the head diff against protected main is not answerable'

# --- change set: from the fork point, never refused for being empty ----------
# A head behind the tip is judged from its fork point: its own commits, not
# main's newer one.
[[ "$(cd "$fixture/pr" && proof_fork_point "$main_tip" "$topic")" == "$fork" ]] ||
  fail 'the fork point of a head behind the tip is not its merge-base'
(cd "$fixture/pr" && proof_changed_paths "$fork" "$topic" "$fixture/changed")
[[ "$(tr '\0' ' ' < "$fixture/changed")" == 't1 t2 t3 ' ]] ||
  fail 'the change set of a head behind the tip is not its own commits'
# Protected main gating its own head: the fork point is the tip and the change
# set is empty, which the lane passes rather than refuses.
[[ "$(cd "$fixture/pr" && proof_fork_point "$main_tip" "$main_tip")" == "$main_tip" ]] ||
  fail 'the fork point of main'"'"'s own head is not the tip'
(cd "$fixture/pr" && proof_changed_paths "$main_tip" "$main_tip" "$fixture/changed") ||
  fail 'main'"'"'s own head was refused'
[[ ! -s "$fixture/changed" ]] || fail 'main'"'"'s own head has a non-empty change set'
# An unrelated history has no fork point.
git init -q -b main "$fixture/other"
commit "$fixture/other" o1
git -C "$fixture/pr" fetch -q "$fixture/other" main
other="$(git -C "$fixture/other" rev-parse HEAD)"
if (cd "$fixture/pr" && proof_fork_point "$main_tip" "$other") 2>/dev/null; then
  fail 'accepted a head that shares no history with protected main'
fi
# A failing diff fails the guard instead of reading as an empty change set.
if (cd "$fixture/pr" && proof_changed_paths "$fork" 0000000000000000000000000000000000000000 "$fixture/changed") 2>/dev/null; then
  fail 'a failed diff read as an empty change set'
fi
printf 'proof change-set guard ok\n'

# An unreachable forge fails the guard.
git clone -q --depth 1 --branch topic "file://$fixture/forge.git" "$fixture/pr-gone"
git -C "$fixture/pr-gone" remote set-url origin "file://$fixture/missing.git"
if (cd "$fixture/pr-gone" && proof_require_history) 2>/dev/null; then
  fail 'accepted a failed history fetch'
fi
unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
printf 'proof history guard ok\n'

# --- migration: the pinned tool's real output --------------------------------
real=ops/ci/tests/fixtures/jankurai-1.7.5-migrate-analyze.json
jq '.source_root = "/base"' "$real" > "$fixture/base"
cp "$real" "$fixture/head"
proof_require_migration "$fixture/base" /base "$fixture/head" . ||
  fail 'rejected the pinned tool'"'"'s own output'
# Lower liability may drop a lane; equal liability may not.
jq '.liability_score -= 1 | .required_proof_lanes = ["fast"]' "$real" > "$fixture/head"
proof_require_migration "$fixture/base" /base "$fixture/head" . ||
  fail 'rejected a head that lowered liability'
for filter in '.liability_score += 1' '.status = "partial"' 'del(.liability_score)' \
    '.liability_score = -1' '.required_proof_lanes = ["fast"]' '.schema_version = "2.0.0"' \
    '.source_root = "/elsewhere"' '.required_proof_lanes = "fast"'; do
  jq "$filter" "$real" > "$fixture/head"
  if proof_require_migration "$fixture/base" /base "$fixture/head" . 2>/dev/null; then
    fail "accepted migration regression: $filter"
  fi
done
cp "$real" "$fixture/head"
jq '.status = "partial" | .source_root = "/base"' "$real" > "$fixture/bad-base"
if proof_require_migration "$fixture/bad-base" /base "$fixture/head" . 2>/dev/null; then
  fail 'accepted an incomplete baseline analysis'
fi
# Free-text notes are not gated, on either side.
jq '.rollback_cutover_notes = []' "$real" > "$fixture/head"
proof_require_migration "$fixture/base" /base "$fixture/head" . ||
  fail 'gated on free-text rollback notes'
printf 'proof migration guard ok\n'

# --- wiring tripwires ---------------------------------------------------------
lane=ops/ci/proof_evidence.sh

grep -n '|| true' "$lane" | grep -qv 'cleanup_baseline || true' &&
  fail 'a literal `|| true` discards a tool failure in the lane' || :
grep -q 'git clone --quiet --no-local' "$lane" ||
  fail 'the ratchet baseline is not cloned from protected main'
grep -q 'agent/baselines' "$lane" &&
  fail 'the lane names agent/baselines, an in-tree baseline' || :
grep -q 'candidate audit policy must be byte-identical to protected main' "$lane" ||
  fail 'the lane does not check that main policy judges this head'
# Every `>` redirect into target/ is this run's summary; a `printf > target/...`
# fallback would be a result nobody produced. (cp and tee are not covered.)
while IFS= read -r line; do
  [[ "$line" == '  > target/jankurai/proof-evidence-summary.json' ]] ||
    fail "the lane redirects into target/: $line"
done < <(grep -E '> *target/' "$lane" | grep -v '^[[:space:]]*#')

line_of() {
  local n
  n="$(grep -n -m1 -e "$1" "$2" | cut -d: -f1)"
  [[ -n "$n" ]] || fail "$2 does not contain: $1"
  printf '%s\n' "$n"
}
(( $(line_of 'git remote get-url origin' "$lane") < $(line_of '^proof_require_history$' "$lane") )) ||
  fail 'the lane fetches from origin before checking it is the hosted repository'
(( $(line_of '^proof_require_history$' "$lane") < $(line_of 'proof_fork_point' "$lane") )) ||
  fail 'ancestry is asked before the checkout has its history'
grep -q 'refuses an empty' "$lane" &&
  fail 'the lane refuses an empty change set, so protected main fails its own gate' || :
(( $(line_of '^rm -rf -- \\$' "$lane") < $(line_of '^ *jankurai proof \.' "$lane") )) ||
  fail 'the lane runs a tool before clearing an earlier run artifacts'
(( $(line_of '^jankurai migrate \.' "$lane") < $(line_of '^proof_require_migration' "$lane") )) ||
  fail 'the migration gate reads a report the lane did not just produce'

pr_ci=ops/ci/pr-ci.sh
grep -qx 'bash ops/ci/proof_evidence.sh' "$pr_ci" || fail 'pr-ci.sh does not run the proof lane'
(( $(line_of '^cargo nextest run' "$pr_ci") < $(line_of '^bash ops/ci/proof_evidence.sh$' "$pr_ci") )) ||
  fail 'the proof lane runs before the workspace test suite'
(( $(line_of '^bash tests/sandbox_escape_matrix.sh$' "$pr_ci") < $(line_of '^bash ops/ci/proof_evidence.sh$' "$pr_ci") )) ||
  fail 'the proof lane runs before the sandbox escape matrix'

grep -q '^name = "proof-evidence"$' agent/proof-lanes.toml ||
  fail 'the lane is not in the repository lane catalog'
grep -q '^command = "bash ops/ci/proof_evidence.sh"$' agent/proof-lanes.toml ||
  fail 'the catalog does not name the command the gate runs'
printf 'proof lane wiring ok\n'
