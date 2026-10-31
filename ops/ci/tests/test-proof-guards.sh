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
mkdir -p target
fixture="$(mktemp -d "$PWD/target/proof-guards.XXXXXXXX")"
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

# --- base ref: the protected tip, or the commit before it, and nothing else ---
# Only two spellings are accepted, both resolved from the protected
# remote-tracking ref the lane refreshes itself, so no caller, pull request or
# branch can name the commit this head is judged against.
[[ "$(JERYU_JANKURAI_BASE_REF= proof_base_ref)" == origin/main ]] ||
  fail 'the default proof base is not protected origin/main'
[[ "$(unset JERYU_JANKURAI_BASE_REF; proof_base_ref)" == origin/main ]] ||
  fail 'an unset proof base is not protected origin/main'
# The supported retry must be main's exact refreshed tip, and resolves its parent
# to an immutable commit before any other fetch can move origin/main.
git clone -q --branch main "file://$fixture/forge.git" "$fixture/retry"
retry_base=$(cd "$fixture/retry" && proof_require_history && JERYU_JANKURAI_BASE_REF=origin/main~1 proof_base_ref)
[[ "$retry_base" == "$fork" ]] || fail 'main retry did not bind its exact parent commit'
if (cd "$fixture/pr" && JERYU_JANKURAI_BASE_REF=origin/main~1 proof_base_ref) 2>/dev/null; then
  fail 'a pull request could opt into the prior-tip main baseline'
fi
# The real proof history fetch advances main after admission, as it can in the
# final proof lane after a long recipe. Refuse, never take the empty-diff pass.
commit "$fixture/work" m3
git -C "$fixture/work" push -q "$fixture/forge.git" main
(cd "$fixture/retry" && proof_require_history)
if (cd "$fixture/retry" && JERYU_JANKURAI_BASE_REF=origin/main~1 proof_base_ref) 2>/dev/null; then
  fail 'main moving during the proof history fetch allowed a vacuous retry'
fi
(cd "$fixture/retry" && proof_changed_paths "$retry_base" "$main_tip" "$fixture/retry-changed")
[[ -s "$fixture/retry-changed" ]] || fail 'the resolved parent changed when main moved'
for refused in origin/release/v1 main HEAD HEAD~1 "$fork" origin/main~2 origin/main~ \
               'origin/main^' 'origin/main~1 ' refs/remotes/origin/main; do
  if out="$(JERYU_JANKURAI_BASE_REF="$refused" proof_base_ref 2>/dev/null)"; then
    fail "proof base $refused was accepted as $out"
  fi
done
printf 'proof base ref guard ok\n'

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

# --- summary: v2, both shapes, from files this run wrote ----------------------
summary_root="$fixture/summary"
mkdir -p "$summary_root/target/jankurai/security" "$summary_root/target/security" \
  "$summary_root/target/jankurai/proofmark"
printf '{}' > "$summary_root/target/jankurai/security/evidence.json"
printf '{}' > "$summary_root/target/security/evidence.json"
printf '{}' > "$summary_root/target/security/sbom.cdx.json"
printf '{"liability_score": 3}' > "$summary_root/target/jankurai/migration-report.json"
printf '{"liability_score": 4}' > "$summary_root/target/jankurai/baseline-migration-report.json"
h=1111111111111111111111111111111111111111; b=2222222222222222222222222222222222222222
# Empty change set: no proof artifacts exist, and none are named.
(cd "$summary_root" && proof_evidence_summary "$h" "$b" "$b" target/jankurai/proof-receipts/run-x 0 0 94 abc) \
  > "$fixture/empty.json" || fail 'the summary refused an empty change set'
jq -e --arg h "$h" --arg b "$b" '
  .schema_version == "jeryu.ci-runner.proof-evidence/v2" and .git_head == $h and
  .base_commit == $b and .fork_point == $b and .changed_path_count == 0 and
  .receipt_count == 0 and .receipt_dir == null and .proof_plan_sha256 == null and
  .evidence_index_sha256 == null and .proof_verification_sha256 == null and
  .proofmark_review_obligations == null and .proof_verification == "not_applicable" and
  .migration_liability_score == 3 and .baseline_migration_liability_score == 4 and
  .conclusion == "success"' "$fixture/empty.json" >/dev/null ||
  fail 'the empty-change-set summary is not the v2 shape'
if (cd "$summary_root" && proof_evidence_summary "$h" "$b" "$b" r 0 2 94 abc) >/dev/null 2>&1; then
  fail 'an empty change set was summarised with receipts'
fi
# A non-empty change set must have every proof artifact; a missing one fails.
if (cd "$summary_root" && proof_evidence_summary "$h" "$b" "$b" r 3 2 94 abc) >/dev/null 2>&1; then
  fail 'a non-empty change set was summarised without its proof artifacts'
fi
if (cd "$summary_root" && proof_evidence_summary "$h" "$b" "$b" r 3 0 94 abc) >/dev/null 2>&1; then
  fail 'a non-empty change set was summarised with no receipts'
fi
printf '{"p":1}' > "$summary_root/target/jankurai/proof-plan.json"
printf '{"i":1}' > "$summary_root/target/jankurai/evidence-index.json"
printf '{"v":1}' > "$summary_root/target/jankurai/proof-verification.json"
printf '{"summary":{"review_obligations":1}}' > "$summary_root/target/jankurai/proofmark/proofmark-receipt.json"
(cd "$summary_root" && proof_evidence_summary "$h" "$b" "$b" r 3 2 94 abc) \
  > "$fixture/full.json" || fail 'the summary refused a complete non-empty change set'
plan_sum="$(sha256sum "$summary_root/target/jankurai/proof-plan.json" | cut -d' ' -f1)"
jq -e --arg plan "$plan_sum" '
  .changed_path_count == 3 and .receipt_count == 2 and .receipt_dir == "r" and
  .proof_plan_sha256 == $plan and (.evidence_index_sha256 | test("^[0-9a-f]{64}$")) and
  (.proof_verification_sha256 | test("^[0-9a-f]{64}$")) and
  .proofmark_review_obligations == 1 and .proof_verification == "pass"' \
  "$fixture/full.json" >/dev/null || fail 'the non-empty summary does not bind its artifacts'
printf 'proof summary ok\n'

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

# Policy stays protected-main bytes unless a digest-pinned transition is authorized.
g=proof_require_governed_policy
printf '%s\n' 'minimum_score = 80' 'required_tool_version = "1.7.5"' > "$fixture/protected-policy"
printf '%s\n' 'minimum_score = 80' 'required_tool_version = "1.7.6"' > "$fixture/candidate-policy"
pd="$(sha256sum "$fixture/protected-policy" | cut -d' ' -f1)"
cd_="$(sha256sum "$fixture/candidate-policy" | cut -d' ' -f1)"
zero="$(printf '%064d' 0)"
$g "$fixture/protected-policy" "$fixture/protected-policy" || fail 'identical policy refused'
if $g "$fixture/candidate-policy" "$fixture/protected-policy" 2>/dev/null; then fail 'unauthorized policy change accepted'; fi
if $g "$fixture/candidate-policy" "$fixture/protected-policy" "$fixture/missing" 2>/dev/null; then fail 'missing authorization accepted'; fi
printf '# pinned\n\n%s %s\n' "$pd" "$cd_" > "$fixture/authz"
$g "$fixture/candidate-policy" "$fixture/protected-policy" "$fixture/authz" || fail 'pinned transition refused'
printf '%s %s\n' "$cd_" "$pd" > "$fixture/authz-rev"
if $g "$fixture/candidate-policy" "$fixture/protected-policy" "$fixture/authz-rev" 2>/dev/null; then fail 'reversed pin accepted'; fi
printf '%s %s\n' "$pd" "$zero" > "$fixture/authz-other"
if $g "$fixture/candidate-policy" "$fixture/protected-policy" "$fixture/authz-other" 2>/dev/null; then fail 'pin for another candidate accepted'; fi
printf '%s\n' 'minimum_score = 79' 'required_tool_version = "1.7.6"' > "$fixture/tampered-policy"
if $g "$fixture/tampered-policy" "$fixture/protected-policy" "$fixture/authz" 2>/dev/null; then fail 'tampered floor accepted under a pin for other bytes'; fi
printf '%s %s extra\n' "$pd" "$cd_" > "$fixture/authz-bad"
if $g "$fixture/candidate-policy" "$fixture/protected-policy" "$fixture/authz-bad" 2>/dev/null; then fail 'malformed authorization accepted'; fi
ln -s authz "$fixture/authz-link"
if $g "$fixture/candidate-policy" "$fixture/protected-policy" "$fixture/authz-link" 2>/dev/null; then fail 'symlinked authorization accepted'; fi
cp "$fixture/authz" "$fixture/authz-hard"; ln "$fixture/authz-hard" "$fixture/authz-hard2"
if $g "$fixture/candidate-policy" "$fixture/protected-policy" "$fixture/authz-hard" 2>/dev/null; then fail 'multiply linked authorization accepted'; fi
printf '%s\t%s\n' "$pd" "$cd_" > "$fixture/authz-tab"
$g "$fixture/candidate-policy" "$fixture/protected-policy" "$fixture/authz-tab" || fail 'tab-separated pin refused'
# A pin buys those exact bytes, never a lower merge floor.
printf '%s\n' 'minimum_score = 79' 'required_tool_version = "1.7.5"' > "$fixture/lower-policy"
lower="$(sha256sum "$fixture/lower-policy" | cut -d' ' -f1)"
printf '%s %s\n' "$pd" "$lower" > "$fixture/authz-lower"
if $g "$fixture/lower-policy" "$fixture/protected-policy" "$fixture/authz-lower" 2>/dev/null; then fail 'pinned floor reduction accepted'; fi
printf '%s\n' 'minimum_score = 81' 'required_tool_version = "1.7.5"' > "$fixture/raise-policy"
raise="$(sha256sum "$fixture/raise-policy" | cut -d' ' -f1)"
printf '%s %s\n' "$pd" "$raise" > "$fixture/authz-raise"
$g "$fixture/raise-policy" "$fixture/protected-policy" "$fixture/authz-raise" || fail 'pinned floor raise refused'
# A pin to bytes whose floor cannot be read at all refuses rather than passes.
printf '%s\n' 'minimum_score = 80' 'minimum_score = 70' > "$fixture/dup-policy"
dup="$(sha256sum "$fixture/dup-policy" | cut -d' ' -f1)"
printf '%s %s\n' "$pd" "$dup" > "$fixture/authz-dup"
if $g "$fixture/dup-policy" "$fixture/protected-policy" "$fixture/authz-dup" 2>/dev/null; then fail 'pinned duplicate floor accepted'; fi
# One malformed line refuses the file, including pins listed before it.
printf '%s %s\nnot-a-pin\n' "$pd" "$cd_" > "$fixture/authz-trailing"
if $g "$fixture/candidate-policy" "$fixture/protected-policy" "$fixture/authz-trailing" 2>/dev/null; then fail 'pin before a malformed line accepted'; fi
# A pin buys those exact bytes: beyond the digest pair the only field compared
# is the numeric minimum_score, so a pinned pair that keeps the floor and
# differs elsewhere is accepted here and rests on the review that landed it.
printf '%s\n' 'minimum_score = 80' 'hard_findings_allowed = 3' > "$fixture/other-field-policy"
other="$(sha256sum "$fixture/other-field-policy" | cut -d' ' -f1)"
printf '%s %s\n' "$pd" "$other" > "$fixture/authz-other-field"
$g "$fixture/other-field-policy" "$fixture/protected-policy" "$fixture/authz-other-field" ||
  fail 'a pinned pair that keeps the merge floor was refused'
printf 'proof governed policy guard ok\n'

# --- the baseline clone this gate scored against must still be main's bytes ---
git init -q -b main "$fixture/protected"
cp .gitignore "$fixture/protected/.gitignore"
mkdir -p "$fixture/protected/agent"
printf '%s\n' 'minimum_score = 80' > "$fixture/protected/agent/audit-policy.toml"
printf 'protected source\n' > "$fixture/protected/source.txt"
git -C "$fixture/protected" add -A
git -C "$fixture/protected" commit -q --no-gpg-sign -m policy
pbase="$(git -C "$fixture/protected" rev-parse HEAD)"
pdigest="$(sha256sum "$fixture/protected/agent/audit-policy.toml" | cut -d' ' -f1)"
b=proof_require_protected_baseline
$b "$fixture/protected" "$pbase" "$pdigest" || fail 'untouched baseline refused'
c=proof_require_clean_baseline_clone
$c "$fixture/protected" "$pbase" || fail 'untouched fresh clone refused'
if $c "$fixture/protected" "$zero" 2>/dev/null; then fail 'fresh clone at wrong head accepted'; fi
# The audit's own untracked output does not count as a change.
mkdir -p "$fixture/protected/.jankurai"
printf '{}\n' > "$fixture/protected/.jankurai/repo-score.json"
$b "$fixture/protected" "$pbase" "$pdigest" || fail 'baseline audit output counted as a change'
if $c "$fixture/protected" "$pbase" 2>/dev/null; then fail 'fresh clone with audit output accepted'; fi
# Editing the policy in the baseline tree is caught, and so is committing it.
printf '%s\n' 'minimum_score = 70' > "$fixture/protected/agent/audit-policy.toml"
if $b "$fixture/protected" "$pbase" "$pdigest" 2>/dev/null; then fail 'edited baseline policy accepted'; fi
git -C "$fixture/protected" -c user.name=t -c user.email=t@invalid \
  commit -q --no-gpg-sign -m tamper -- agent/audit-policy.toml
if $b "$fixture/protected" "$pbase" "$pdigest" 2>/dev/null; then fail 'committed baseline policy edit accepted'; fi
git -C "$fixture/protected" checkout -q --detach "$pbase"
printf 'candidate source\n' > "$fixture/protected/source.txt"
if $b "$fixture/protected" "$pbase" "$pdigest" 2>/dev/null; then fail 'edited non-policy baseline input accepted'; fi
git -C "$fixture/protected" restore source.txt
# Untracked paths: the baseline audit's own .jankurai output at any depth is
# allowed, and any other untracked path refuses -- it would be scored and
# analysed as if protected main carried it.
mkdir -p "$fixture/protected/.jankurai/history"
printf '{}\n' > "$fixture/protected/.jankurai/history/run.json"
$b "$fixture/protected" "$pbase" "$pdigest" || fail 'nested baseline audit output refused'
printf 'fn injected() {}\n' > "$fixture/protected/injected.rs"
if $b "$fixture/protected" "$pbase" "$pdigest" 2>/dev/null; then fail 'an untracked input in the baseline tree accepted'; fi
rm -f -- "$fixture/protected/injected.rs"
mkdir -p "$fixture/protected/jankurai"
printf '{}\n' > "$fixture/protected/jankurai/not-audit-output.json"
if $b "$fixture/protected" "$pbase" "$pdigest" 2>/dev/null; then fail 'an untracked path merely resembling the audit output accepted'; fi
rm -rf -- "$fixture/protected/jankurai"
# Use the repository's real .gitignore, not synthetic exclude rules. Output
# allowance must never hide a sibling ignored input in the same directory.
$b "$fixture/protected" "$pbase" "$pdigest" || fail 'ignored baseline audit output refused'
# Jankurai's exact state output is permitted after auditing, never before it.
mkdir -p "$fixture/protected/target/jankurai"
printf '{}\n' > "$fixture/protected/target/jankurai/audit-state.json"
$b "$fixture/protected" "$pbase" "$pdigest" || fail 'real audit state output refused'
if $c "$fixture/protected" "$pbase" 2>/dev/null; then fail 'fresh clone with ignored output accepted'; fi
for ignored in target/x.rs target/jankurai/extra.rs sub/target/x.rs dist/x.rs x.receipt.json; do
  mkdir -p "$fixture/protected/$(dirname "$ignored")"
  printf 'fn planted() {}\n' > "$fixture/protected/$ignored"
  if $b "$fixture/protected" "$pbase" "$pdigest" 2>/dev/null; then fail "an ignored input in the baseline tree accepted: $ignored"; fi
  rm -f -- "$fixture/protected/$ignored"
  rm -rf -- "$fixture/protected/sub" "$fixture/protected/dist" "$fixture/protected/x.receipt.json"
done
$b "$fixture/protected" "$pbase" "$pdigest" || fail 'baseline refused after the stray inputs were removed'
# Exact-name allowance never follows a symlink or shared inode.
state="$fixture/protected/target/jankurai/audit-state.json"
rm -- "$state"
ln -s /dev/null "$state"
if $b "$fixture/protected" "$pbase" "$pdigest" 2>/dev/null; then fail 'symlink audit state accepted'; fi
rm -- "$state"
printf '{}\n' > "$fixture/shared-state"
ln "$fixture/shared-state" "$state"
if $b "$fixture/protected" "$pbase" "$pdigest" 2>/dev/null; then fail 'hardlinked audit state accepted'; fi
rm -- "$state"

if $b "$fixture/protected" "$pbase" "$zero" 2>/dev/null; then fail 'wrong baseline policy digest accepted'; fi
printf 'invalid index\n' > "$fixture/protected/.git/index"
if $b "$fixture/protected" "$pbase" "$pdigest" 2>/dev/null; then fail 'failed baseline status read accepted'; fi
if $c "$fixture/protected" "$pbase" 2>/dev/null; then fail 'failed fresh clone status read accepted'; fi
printf 'proof protected baseline guard ok\n'

# --- the authorization file the lane really reads ----------------------------
authz_path=ops/ci/policy-transitions.txt
[[ -f "$authz_path" && ! -L "$authz_path" ]] ||
  fail 'the protected-main policy transition file is missing'
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in ''|'#'*) continue ;; esac
  [[ "$line" =~ ^[0-9a-f]{64}[[:space:]]+[0-9a-f]{64}$ ]] ||
    fail "ops/ci/policy-transitions.txt has an unparsable line: $line"
done < "$authz_path"
# This head carries main's own policy, so it needs no pin: the file is checked
# for shape, and the guard accepts this tree against itself with it in place.
proof_require_governed_policy agent/audit-policy.toml agent/audit-policy.toml "$authz_path" ||
  fail 'the real transition file refuses an unchanged policy'
printf 'proof policy transition file ok\n'

# --- the historical 1.7.5 -> 1.7.6 pin: two immutable preimages, and inert ----
# The pin's two digests are claims about two exact files, and both are kept as
# fixtures. The live policy may evolve, but must not become the historical
# protected preimage again; otherwise this entry could authorize it. The
# lane still checks live policy authority. The pair must differ only in the
# pinned auditor version, and the pin must be inert: it cannot carry the later
# bytes back to the earlier ones.
hist_from=ops/ci/tests/fixtures/audit-policy-1.7.5-preimage.toml
hist_to=ops/ci/tests/fixtures/audit-policy-1.7.6-preimage.toml
for f in "$hist_from" "$hist_to"; do
  [[ -f "$f" && ! -L "$f" ]] || fail "the historical policy preimage is missing: $f"
done
hist_from_sha="$(sha256sum "$hist_from" | cut -d' ' -f1)"
hist_to_sha="$(sha256sum "$hist_to" | cut -d' ' -f1)"
live_policy_sha="$(sha256sum agent/audit-policy.toml | cut -d' ' -f1)" ||
  fail 'cannot hash live audit policy'
[[ "$live_policy_sha" != "$hist_from_sha" ]] ||
  fail 'live policy reactivates the historical protected-side pin'
historical_pinned=
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in ''|'#'*) continue ;; esac
  read -r pin_protected pin_candidate <<<"$line"
  [[ "$pin_protected" == "$hist_from_sha" && "$pin_candidate" == "$hist_to_sha" ]] &&
    historical_pinned=1
done < "$authz_path"
[[ -n "$historical_pinned" ]] ||
  fail 'the historical pin does not name the two preimage digests'
[[ "$hist_from_sha" != "$hist_to_sha" ]] ||
  fail 'the historical pin preimages are the same bytes'
pinned_version() { sed -n 's/^required_tool_version = "\(.*\)"$/\1/p' "$1"; }
[[ "$(pinned_version "$hist_from")" == 1.7.5 ]] ||
  fail 'the protected-side preimage does not pin auditor 1.7.5'
[[ "$(pinned_version "$hist_to")" == 1.7.6 ]] ||
  fail 'the candidate-side preimage does not pin auditor 1.7.6'
blind_version() { sed 's/^required_tool_version = ".*"$/required_tool_version = "pinned"/' "$1"; }
diff <(blind_version "$hist_from") <(blind_version "$hist_to") >/dev/null ||
  fail 'the historical pin pair differs by more than the pinned auditor version'
# The recorded transition is accepted as recorded, with the fixtures alone.
proof_require_governed_policy "$hist_to" "$hist_from" "$PWD/$authz_path" ||
  fail 'the recorded historical transition is refused'
# Inert in the direction that matters: the reverse pair is not pinned.
if proof_require_governed_policy "$hist_from" "$hist_to" "$PWD/$authz_path" 2>/dev/null; then
  fail 'the historical pin authorizes reverting the policy to its 1.7.5 preimage'
fi
printf 'historical policy pin preimages ok\n'

# --- wiring tripwires ---------------------------------------------------------
lane=ops/ci/proof_evidence.sh

# Every scan below reads text held in a variable rather than piping one grep
# into another, and reads grep's own status rather than spelling the scan
# `... | grep -q X && fail ... || :`. That idiom treats every non-zero status as
# "nothing matched": a grep that could not run at all (status 2 -- an unreadable
# file, a pattern this grep rejects) passes, and so does a pipeline whose
# writing grep was killed by SIGPIPE once the reading `grep -q` stopped at its
# first match, which `set -o pipefail` surfaces as the pipeline's status.
# scan_hits runs grep with the given arguments and leaves what matched in
# $HITS. Status 0 is hits and 1 is a clean scan; anything else is a scan that
# did not run and fails the test, so an unreadable file never reads as "nothing
# matched". It runs in the current shell, never inside `$(...)`, because an
# exit in a command substitution would end only the substitution.
HITS=
scan_hits() {
  local rc=0
  HITS="$(grep "$@")" || rc=$?
  case "$rc" in
    0|1) ;;
    *) fail "a lane scan did not run (grep status $rc)" ;;
  esac
}
# A scan that cannot run must fail the test, not read as a clean scan.
if (scan_hits -n x "$fixture/no-such-lane-file") 2>/dev/null; then
  fail 'a scan of an unreadable file passed as clean'
fi
(scan_hits -n x /dev/null) || fail 'a clean scan was refused'

scan_hits -n '|| true' "$lane"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  [[ "$line" == *'cleanup_baseline || true' ]] ||
    fail 'a literal `|| true` discards a tool failure in the lane'
done <<<"$HITS"
grep -q 'git clone --quiet --no-local' "$lane" ||
  fail 'the ratchet baseline is not cloned from protected main'
scan_hits -n 'agent/baselines' "$lane"
[[ -z "$HITS" ]] ||
  fail 'the lane names agent/baselines, an in-tree baseline'
grep -q 'proof_require_governed_policy "$candidate_policy" "$baseline_policy"' "$lane" ||
  fail 'the lane does not check that main policy judges this head'
grep -q 'ops/ci/policy-transitions.txt' "$lane" ||
  fail 'the lane does not read transitions from the protected-main tree'
# Any write whose target is the baseline policy or the baseline tree's policy
# path, however it is spelled, puts the candidate's bytes in main's place.
scan_hits -nE '(cp|mv|install|tee|ln|printf|cat|sed)[^|&;]*\$\{?baseline_policy|> *"?\$\{?baseline_policy' "$lane"
[[ -z "$HITS" ]] ||
  fail 'the lane writes to the protected-main baseline policy'
# The lane reads history and never writes it. `HEAD^{commit}` and
# `${base_commit}` are reads, so only `commit` in git's subcommand position
# counts -- it is the shape the baseline mutation took. A subcommand ends the
# line as often as it is followed by an argument, and `git \` continues onto a
# line that then starts with it, so neither a trailing nor a continued `commit`
# may slip through. Status 0 is a hit, 1 is a clean scan, anything else is a
# scan that did not run and is never read as a clean one.
text_runs_commit() {
  local body rc=0
  scan_hits -vE '^[[:space:]]*#' <<<"$1"
  body="$HITS"
  grep -qE '(^|[^_{[:alnum:]])commit([[:space:];&|)]|$)' <<<"$body" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) fail "the commit scan did not run (status $rc)" ;;
  esac
}
# The static tripwire is a line regex, not a shell parser. It catches `commit`
# at line start or after any character except alphanumeric, `_` or `{`, and
# across a `git \` continuation. It does not see a quoted subcommand
# (`git "commit"`), a variable holding it, or an alias; those are covered only
# by the runtime guards, proof_require_protected_baseline's HEAD, tracked-file
# and untracked/ignored-path checks, which the lane runs three times.
! text_runs_commit "$(cat "$lane")" || fail 'the lane runs git commit'
# The tripwire itself, against the forms it must catch and the reads it must not.
while IFS= read -r form; do
  text_runs_commit "$form" || fail "the commit tripwire misses: $form"
done <<'COMMIT_FORMS'
git -C "${baseline_parent}/repo" commit -q -m tamper
git commit
git -C "${baseline_parent}/repo" -c user.name=t commit
	commit --allow-empty -m x
commit -am x
(cd "$repo" && git commit)
git commit;
git commit&
git -C "$repo" commit|cat
COMMIT_FORMS
# A `git \` continuation whose subcommand lands on the next line.
continued='git -C "${baseline_parent}/repo" \
  commit --allow-empty'
text_runs_commit "$continued" || fail 'the commit tripwire misses a continued git commit'
while IFS= read -r form; do
  ! text_runs_commit "$form" || fail "the commit tripwire false-positives on: $form"
done <<'COMMIT_READS'
git rev-parse --verify 'HEAD^{commit}'
base_commit="$(git rev-parse --verify "${BASE_REF}^{commit}")"
report="$(precommit_summary)"
printf 'base=%s\n' "${base_commit}"
# the lane must never run git commit
COMMIT_READS
grep -q 'proof_require_protected_baseline' "$lane" ||
  fail 'the lane does not verify the baseline stayed protected-main bytes'
# Every `>` redirect into target/ is this run's summary; a `printf > target/...`
# fallback would be a result nobody produced. (cp and tee are not covered.)
scan_hits -E '> *target/' "$lane"
redirects="$HITS"
scan_hits -v '^[[:space:]]*#' <<<"$redirects"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  [[ "$line" == '  > target/jankurai/proof-evidence-summary.json' ]] ||
    fail "the lane redirects into target/: $line"
done <<<"$HITS"

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
scan_hits -nE "mapfile .*< <\(" "$lane"
[[ -z "$HITS" ]] ||
  fail 'the lane reads its change set through a process substitution set -e cannot see'
grep -q 'was not read in full' "$lane" ||
  fail 'the lane does not check that its whole change set was read'
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
(( $(line_of '^proof_require_history$' "$lane") < $(line_of 'BASE_REF="$(proof_base_ref)"' "$lane") )) ||
  fail 'the main retry baseline was selected before protected history was refreshed'
printf 'proof lane wiring ok\n'

# --- security lane failure evidence survives cleanup of target/ ---------------
sec="$fixture/security-lane"
mkdir -p "$sec/tools" "$sec/ops/ci"
cp tools/security-lane.sh "$sec/tools/security-lane.sh"
cat > "$sec/ops/ci/lib.sh" <<'LIB'
require_tool() {
  printf 'wrapper-stdout-marker %s\n' "$1"
  printf 'wrapper-stderr-marker missing tool %s\n' "$1" >&2
  return 7
}
LIB
sec_rc=0
(cd "$sec" && bash tools/security-lane.sh --strict >/dev/null 2>&1) || sec_rc=$?
[[ "$sec_rc" -ne 0 ]] || fail 'a failing security wrapper exited zero'
# The attempt log is what outlives cleanup; replay into it, then delete target/.
(cd "$sec" && proof_report_security_failure "$sec_rc") 2> "$fixture/attempt-build.log"
rm -rf -- "$sec/target"
grep -q 'command=bash tools/security-lane.sh --strict' "$fixture/attempt-build.log" ||
  fail 'the failure evidence lost the wrapper command identity'
grep -q "^exit_status=$sec_rc\$" "$fixture/attempt-build.log" ||
  fail 'the failure evidence lost the wrapper exit status'
grep -q 'wrapper-stdout-marker gitleaks' "$fixture/attempt-build.log" ||
  fail 'the failure evidence lost the wrapper stdout'
grep -q 'wrapper-stderr-marker missing tool gitleaks' "$fixture/attempt-build.log" ||
  fail 'the failure evidence lost the wrapper stderr'
grep -q 'proof_report_security_failure' ops/ci/proof_evidence.sh ||
  fail 'the proof lane does not report a failed security run'
printf 'security failure evidence ok\n'

[[ "$(grep -c '^proof_require_protected_baseline' "$lane")" == 3 ]] ||
  fail 'baseline integrity is not checked before audit, after audit, and after migration'
(( $(line_of '^proof_require_migration' "$lane") < $(grep -n '^proof_require_protected_baseline' "$lane" | tail -1 | cut -d: -f1) )) ||
  fail 'the final baseline integrity check runs before migration'
(( $(line_of 'proof_require_governed_policy' "$lane") < $(line_of 'baseline_policy_sha256=' "$lane") )) ||
  fail 'the baseline policy digest is recorded before it is accepted as main policy'
# The pre-digest window: before the policy digest pins the baseline tree, the
# clone must already be known to be the exact base commit with nothing modified
# and nothing untracked, and the lane must not redirect into that tree at all.
(( $(line_of '^proof_require_clean_baseline_clone' "$lane") < $(line_of 'proof_require_governed_policy' "$lane") )) ||
  fail 'the baseline clone is read as main bytes before it is known clean'
(( $(line_of '^proof_require_clean_baseline_clone' "$lane") < $(line_of 'baseline_policy_sha256=' "$lane") )) ||
  fail 'the baseline policy digest is recorded before the clone is known clean'
# Fold the lane's line continuations so a check written across lines reads as
# the single command it is.
lane_folded="$(sed -e ':a' -e '/\\$/{N;s/\\\n/ /;ba' -e '}' "$lane" | tr -s ' ')"
grep -Fq 'proof_require_clean_baseline_clone "${baseline_parent}/repo" "$base_commit"' \
  <<<"$lane_folded" ||
  fail 'the baseline clone is not checked for modified and untracked files'
scan_hits -nE '> *"?\$\{baseline_parent\}' "$lane"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  fail "the lane redirects into the protected-main baseline clone: $line"
done <<<"$HITS"
printf 'proof pre-digest window ok\n'
grep -Fqx 'effective_floor="$(audit_effective_floor "${baseline_policy}")"' "$lane" ||
  fail 'the proof floor is not derived from protected-main policy'
scan_hits -n 'audit_base_commit' "$lane"
[[ -z "$HITS" ]] ||
  fail 'the baseline binding can name a synthetic commit'
