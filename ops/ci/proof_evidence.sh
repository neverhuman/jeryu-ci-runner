#!/usr/bin/env bash
# Generate exact-head proof artifacts only from commands that actually ran.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"
# shellcheck source=ops/ci/lib.sh
source "${ROOT}/ops/ci/lib.sh"
require_tool jq
require_jankurai
source ops/ci/proof_guards.sh

candidate_policy="${ROOT}/agent/audit-policy.toml"
if [[ ! -f "${candidate_policy}" || -L "${candidate_policy}" ||
      "$(stat -c '%h' -- "${candidate_policy}")" != 1 ||
      "$(realpath -- "${candidate_policy}")" != "${candidate_policy}" ]]; then
  printf 'candidate audit policy must be a canonical one-link regular file\n' >&2
  exit 1
fi

# origin must be the hosted source repository before anything is fetched from it.
if [[ "$(git remote get-url origin)" != \
      'https://git.neverhuman.org/git/jeryu/jeryu-ci-runner.git' ]]; then
  printf 'proof origin is not the hosted source repository\n' >&2
  exit 1
fi
proof_require_history
BASE_REF="$(proof_base_ref)"
base_commit="$(git rev-parse --verify "${BASE_REF}^{commit}")" || {
  printf 'missing proof evidence base: %s\n' "${BASE_REF}" >&2
  exit 1
}
current_head="$(git rev-parse --verify 'HEAD^{commit}')"
# The ratchet baseline is protected main's tip; the change set starts at the
# fork point. A head behind the tip is judged against the tip rather than
# refused, the rule jeryu-jira's lane follows (#21): refusing it turns every
# open pull request red each time main moves. The audit, migration and ratchet
# checks below compare this head's whole tree with the tip's, so a stale head
# that scores below the tip, adds a cap or hard finding, or raises migration
# liability fails them; the proof plan covers this head's own change. Gated
# against protected main's tip, main's own head is a change set of nothing;
# its supported retry resolves its parent SHA after the history fetch (proof_base_ref), so the
# commit that moved main is judged against the main it moved from.
fork_commit="$(proof_fork_point "${base_commit}" "${current_head}")"
if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  printf 'proof evidence requires a clean exact-head checkout\n' >&2
  exit 1
fi

# Every artifact this lane reads must come from this run. A rerun in a retained
# target/ (the gate runner's build cache, a local repeat) would otherwise let a
# previous run's report satisfy a check for a tool that wrote nothing this time.
# Only paths this lane itself produces are removed: target/security/ comes from
# the security lane that ran before it, and target/jankurai/repo-score.* is the
# score lane's uploaded report until this lane's ratchet audit replaces it (the
# ratchet report is then bound to this head before it is read), so a failure
# earlier in this lane leaves the score lane's evidence in place.
rm -rf -- \
  target/jankurai/accepted-baseline.json \
  target/jankurai/baseline-migration-report.json \
  target/jankurai/baseline-migration-report.md \
  target/jankurai/changed-paths \
  target/jankurai/changed-paths.unsorted \
  target/jankurai/copy-code \
  target/jankurai/evidence-index.json \
  target/jankurai/migration-report.json \
  target/jankurai/migration-report.md \
  target/jankurai/proof-evidence-summary.json \
  target/jankurai/proof-plan.json \
  target/jankurai/proof-plan.md \
  target/jankurai/proof-verification.json \
  target/jankurai/proof-verification.md \
  target/jankurai/proofbind \
  target/jankurai/proofmark \
  target/jankurai/repair-queue.jsonl \
  target/jankurai/rust \
  target/jankurai/security

mkdir -p \
  .jankurai \
  target/jankurai \
  target/jankurai/copy-code \
  target/jankurai/proofbind \
  target/jankurai/proofmark \
  target/jankurai/rust \
  target/jankurai/security

proof_changed_paths "${fork_commit}" "${current_head}" target/jankurai/changed-paths
# Read from the file with a plain redirect (no process substitution, whose
# failure set -e cannot see), then check that every listed path was read: an
# empty change set below is a pass, so a short read must not look like one.
mapfile -d '' -t changed_paths < target/jankurai/changed-paths
if [[ "${#changed_paths[@]}" -ne "$(tr -cd '\0' < target/jankurai/changed-paths | wc -c)" ]]; then
  printf 'proof change set was not read in full from target/jankurai/changed-paths\n' >&2
  exit 1
fi
expected_changed="$(
  printf '%s\0' "${changed_paths[@]:-}" |
    jq -Rs 'split("\u0000") | map(select(length > 0)) | sort | unique'
)"
for changed_path in "${changed_paths[@]}"; do
  if [[ ! -e "${changed_path}" && ! -L "${changed_path}" ]]; then
    printf 'Jankurai 1.6.10 cannot safely classify deleted proof path: %s\n' \
      "${changed_path}" >&2
    exit 1
  fi
done

receipt_dir="target/jankurai/proof-receipts/run-${current_head:0:12}-$$"
# A rerun can reuse this name (same head, recycled pid); every receipt read
# below has to be one this run wrote.
rm -rf -- "${receipt_dir}"
receipt_count=0
if [[ "${#changed_paths[@]}" -eq 0 ]]; then
  # Nothing changed since the fork point (protected main gating its own head):
  # there is no change surface to plan, prove or bind. The audit, security,
  # migration and ratchet checks below still run against this exact head.
  printf 'proof evidence: empty change set from fork point %s; no change surface to prove\n' \
    "${fork_commit}" >&2
else
  jankurai proof . --changed-from "${fork_commit}" --out target/jankurai/proof-plan.json --md target/jankurai/proof-plan.md
  jankurai prove . --plan target/jankurai/proof-plan.json --out-dir "${receipt_dir}" --evidence-index target/jankurai/evidence-index.json

  jq -e \
    --arg head "${current_head}" \
    --argjson changed "${expected_changed}" \
    '.schema_version == "1.0.0" and
     .git_head == $head and
     (.changed_paths | sort | unique) == $changed and
     (.risk_notes | length) == 0 and
     (.human_approval_requirements | length) == 0 and
     ([.route_decisions[] | select(.decision != "pass")] | length) == 0 and
     (.commands | length) > 0' \
    target/jankurai/proof-plan.json >/dev/null
  jq -e \
    --arg head "${current_head}" \
    --arg receipt_dir "${receipt_dir}" \
    --argjson changed "${expected_changed}" \
    '.schema_version == "1.2.0" and
     .git_head == $head and
     .receipt_dir == $receipt_dir and
     (.changed_paths | sort | unique) == $changed and
     (.failed_receipts | length) == 0 and
     (.receipts | length) == (.commands | length) and
     (.receipts | length) > 0' \
    target/jankurai/evidence-index.json >/dev/null
  for receipt in "${receipt_dir}"/*.json; do
    [[ -f "${receipt}" && ! -L "${receipt}" ]] || {
      printf 'missing regular proof receipt in %s\n' "${receipt_dir}" >&2
      exit 1
    }
    jq -e \
      --arg head "${current_head}" \
      '.schema_version == "1.9.0" and .git_head == $head and
       .dirty_worktree == false and .exit_code == 0 and
       (.command | type == "string" and length > 0) and
       (.log_sha256 | test("^sha256:[0-9a-f]{64}$"))' \
      "${receipt}" >/dev/null
  done

  jankurai proof-verify . \
    --plan target/jankurai/proof-plan.json \
    --evidence-index target/jankurai/evidence-index.json \
    --out target/jankurai/proof-verification.json \
    --md target/jankurai/proof-verification.md
  jq -e '.schema_version == "1.0.0" and .verdict == "pass" and
         ((.issues // []) | length) == 0' \
    target/jankurai/proof-verification.json >/dev/null

  # Proofbind/proofmark remain diagnostic in Jankurai 1.6.10: required mode
  # incorrectly demands Rust line/mutation evidence for non-Rust contract prose.
  # They still run without fallbacks, against the exact extant changed surface,
  # and their unresolved review count is retained in the summary below.
  jankurai proofbind verify . --changed-from "${fork_commit}" --mode advisory --proof-receipts "${receipt_dir}" --out target/jankurai/proofbind/surface-witness.json --obligations-out target/jankurai/proofbind/obligations.json --md target/jankurai/proofbind/proofbind.md
  jankurai proofmark rust . --obligations target/jankurai/proofbind/obligations.json --changed-from "${fork_commit}" --mode advisory --out target/jankurai/proofmark/proofmark-receipt.json --proof-receipt target/jankurai/proofmark/proof-receipt.json --md target/jankurai/proofmark/proofmark.md

  receipt_count="$(jq -er '.receipts | length' target/jankurai/evidence-index.json)"
fi

jankurai copy-code . --json target/jankurai/copy-code/report.json --md target/jankurai/copy-code/report.md
jankurai rust map . --out-dir target/jankurai/rust
jankurai rust witness build . --out target/jankurai/rust/witness-graph.json
jankurai rust diagnose . --out target/jankurai/rust/compile-packets.json
security_rc=0
JERYU_SECURITY_NETWORK=1 jankurai security run . --out target/jankurai/security/evidence.json --script tools/security-lane.sh --strict --profile ci || security_rc=$?
if ((security_rc != 0)); then
  proof_report_security_failure "${security_rc}"
  exit "${security_rc}"
fi

# Build the ratchet baseline from authenticated protected main, never from the
# candidate. The no-local clone is exact-SHA isolation and is always removed.
mkdir -p "${ROOT}/target"
baseline_parent="$(mktemp -d "${ROOT}/target/jeryu-ci-runner-baseline.XXXXXXXX")"
cleanup_baseline() {
  case "${baseline_parent}" in
    "${ROOT}/target"/jeryu-ci-runner-baseline.*)
      rm -rf -- "${baseline_parent}"
      ;;
    *)
      printf 'refusing to remove unexpected baseline path: %s\n' \
        "${baseline_parent}" >&2
      return 1
      ;;
  esac
}
baseline_signal() {
  local exit_code="$1"
  trap - EXIT HUP INT TERM
  cleanup_baseline || true
  exit "${exit_code}"
}

trap cleanup_baseline EXIT
trap 'baseline_signal 129' HUP
trap 'baseline_signal 130' INT
trap 'baseline_signal 143' TERM
git clone --quiet --no-local --no-hardlinks --single-branch --branch main \
  'https://git.neverhuman.org/git/jeryu/jeryu-ci-runner.git' \
  "${baseline_parent}/repo"
# Protected main may move forward while this gate runs: the merge queue builds several entries at
# once, and another one landing moves the tip. The baseline stays the tip this gate started from, which
# must still be on protected main's history; a main that no longer contains it (rewritten, or a base
# this gate was never given) still refuses.
if ! git -C "${baseline_parent}/repo" merge-base --is-ancestor "${base_commit}" 'HEAD^{commit}' 2>/dev/null; then
  printf 'protected-main baseline %s is not on the cloned protected main\n' "${base_commit}" >&2
  exit 1
fi
git -C "${baseline_parent}/repo" -c advice.detachedHead=false checkout --quiet --detach "${base_commit}"
if [[ "$(git -C "${baseline_parent}/repo" rev-parse 'HEAD^{commit}')" != \
      "${base_commit}" ||
      -n "$(git -C "${baseline_parent}/repo" status --porcelain=v1 \
        --untracked-files=all --ignored=matching)" ]]; then
  printf 'protected-main baseline clone drifted or is dirty\n' >&2
  exit 1
fi
baseline_policy="${baseline_parent}/repo/agent/audit-policy.toml"
if [[ ! -f "${baseline_policy}" || -L "${baseline_policy}" ||
      "$(stat -c '%h' -- "${baseline_policy}")" != 1 ||
      "$(realpath -- "${baseline_policy}")" != "${baseline_policy}" ]]; then
  printf 'protected-main audit policy must be a canonical one-link regular file\n' >&2
  exit 1
fi
# The baseline is protected-main bytes and is never edited: a differing
# candidate policy needs a digest-pinned transition recorded on protected main.
proof_require_governed_policy "$candidate_policy" "$baseline_policy" \
  "${baseline_parent}/repo/ops/ci/policy-transitions.txt"
# Main's floor judges both trees, including a digest-authorized version change.
effective_floor="$(audit_effective_floor "${baseline_policy}")"
# Record the policy that was just accepted as main's, so the checks below can
# prove the tree that produced the baseline score is still that tree.
#
# Everything between the clone's clean check above and this digest is the
# pre-digest window, and it is covered by that check rather than by the digest:
# the clone was verified to be the exact base commit with no modified tracked
# file and no untracked or ignored path at all, and from there to here the lane only reads
# -- the canonical-file test, the governed-policy comparison and the floor
# derivation. So the bytes hashed here are the bytes the comparison accepted,
# and proof_require_protected_baseline binds them for the rest of the gate: the
# baseline audit may add its own .jankurai output and nothing else.
baseline_policy_sha256="$(sha256sum -- "${baseline_policy}")"
baseline_policy_sha256="${baseline_policy_sha256%% *}"
proof_require_protected_baseline "${baseline_parent}/repo" "$base_commit" \
  "$baseline_policy_sha256"
(
  cd "${baseline_parent}/repo"
  mkdir -p .jankurai
  jankurai audit . --mode advisory --json .jankurai/repo-score.json \
    --md .jankurai/repo-score.md --policy agent/audit-policy.toml \
    --fail-under "${effective_floor}" --full --no-score-history
)
proof_require_protected_baseline "${baseline_parent}/repo" "$base_commit" \
  "$baseline_policy_sha256"
cp "${baseline_parent}/repo/.jankurai/repo-score.json" \
  target/jankurai/accepted-baseline.json
baseline_score="$(jq -er '.score | select(type == "number") | floor' \
  target/jankurai/accepted-baseline.json)"
baseline_sha256="$(sha256sum target/jankurai/accepted-baseline.json | \
  awk '{print $1}')"
# Compare actual completed migration analyses, using the same protected-main
# tree as the audit baseline. A tool's successful exit alone is not evidence
# that its analysis completed or that this head preserved migration liability.
jankurai migrate "${baseline_parent}/repo" --analyze \
  --out target/jankurai/baseline-migration-report.json \
  --md target/jankurai/baseline-migration-report.md
jankurai migrate . --analyze --out target/jankurai/migration-report.json \
  --md target/jankurai/migration-report.md
proof_require_migration \
  target/jankurai/baseline-migration-report.json "${baseline_parent}/repo" \
  target/jankurai/migration-report.json .
# Nothing above may have written to protected main's tree: the baseline score
# and migration liability this head is held to are main's bytes or no result.
proof_require_protected_baseline "${baseline_parent}/repo" "$base_commit" \
  "$baseline_policy_sha256"
trap - EXIT HUP INT TERM
cleanup_baseline

# Jankurai 1.6.11 writes git.head as a 7-character prefix; 1.7 writes the full
# commit id. Either names exactly this commit.
short_base="${base_commit:0:7}"
jq -e --arg base "${short_base}" --arg base_full "${base_commit}" \
  --argjson floor "${effective_floor}" \
  '(.git.head == $base or .git.head == $base_full) and .git.dirty_worktree == false and
   (.score | type == "number") and .decision.minimum_score == $floor and
   .decision.hard_findings == 0 and (.caps_applied | length) == 0 and
   .decision.passed == true' \
  target/jankurai/accepted-baseline.json >/dev/null

jankurai audit . --mode ratchet --baseline target/jankurai/accepted-baseline.json --json target/jankurai/repo-score.json --md target/jankurai/repo-score.md --policy agent/audit-policy.toml --fail-under "${effective_floor}" --repair-queue-jsonl target/jankurai/repair-queue.jsonl --full --no-score-history

short_head="${current_head:0:7}"
if [[ "${#changed_paths[@]}" -gt 0 ]]; then
  jq -e --arg head "${short_head}" --argjson changed "${expected_changed}" \
    '.schema_version == "1.0.0" and .git_head == $head and
     (.changed_paths | sort | unique) == $changed and
     (.summary.changed_surface_count | type == "number")' \
    target/jankurai/proofbind/surface-witness.json >/dev/null
  jq -e --arg head "${short_head}" \
    '.schema_version == "1.0.0" and .git_head == $head and
     (.summary.total_obligations | type == "number") and
     (.summary.satisfied_obligations | type == "number") and
     (.summary.review_obligations | type == "number") and
     (.summary.verdict == "pass" or .summary.verdict == "review")' \
    target/jankurai/proofmark/proofmark-receipt.json >/dev/null
fi
jq -e --arg head "${current_head}" \
  '.schema_version == "1.0.0" and .git_head == $head and
   .lane == "security" and .wrapper.path == "tools/security-lane.sh" and
   .wrapper.strict == true and .exit_code == 0 and
   ([.commands[] | select(.status == "ran" and .exit_code == 0)] | length) >= 1' \
  target/jankurai/security/evidence.json >/dev/null
jq -e --arg head "${current_head}" \
  '.schema_version == "jeryu.split.security/v2" and .git_head == $head and
   .network_dependency_checks == true and .conclusion == "success" and
   .source_name == "jeryu-ci-runner" and
   .source_version == "jeryu-ci-runner-v5.0.0-split.2" and
   (["cargo-audit-0.22.1", "cargo-deny-0.19.8",
     "hosted-dependency-sources", "syft-1.40.0-cyclonedx"] - .checks |
     length) == 0' \
  target/security/evidence.json >/dev/null
# copy-code stamps the version of the binary that ran it; bind it to the
# receipt-verified auditor require_jankurai selected (1.6.11 or 1.7.x).
jq -e --arg root "${ROOT}" --arg auditor "${JERYU_JANKURAI_SEMVER:?require_jankurai did not export JERYU_JANKURAI_SEMVER}" \
  '.schema_version == "1.1.0" and
   .generated_by == "jankurai copy-code" and
   .auditor_version == $auditor and .repo == $root and
   (.status == "pass" or .status == "review") and
   (.classes | type == "array") and
   .summary.hard_classes == 0 and .summary.hard_instances == 0 and
   (.summary.warning_classes | type == "number") and
   (.summary.warning_instances | type == "number") and
   all(.classes[];
     .hard_fail == false and (.instances | type == "array"))' \
  target/jankurai/copy-code/report.json >/dev/null
jq -e --arg root "${ROOT}" \
  '(.generated_at | type == "string" and length > 0) and
   .workspace_root == $root and
   (.crates | type == "array" and length > 0) and
   all(.crates[];
     (.name | type == "string" and length > 0) and
     (.interface_hash | type == "string" and test("^[0-9a-f]{64}$")) and
     (.implementation_hash | type == "string" and test("^[0-9a-f]{64}$")) and
     (.pub_items | type == "array") and
     (.direct_deps | type == "array") and
     (.reverse_deps | type == "array") and
     (.file_count | type == "number" and . > 0) and
     (.total_lines | type == "number" and . > 0))' \
  target/jankurai/rust/witness-graph.json >/dev/null

# Bind and revalidate the protected-main ratchet output at the repository's
# fleet-wide merge floor.
jq -e \
  --arg head "${short_head}" --arg head_full "${current_head}" \
  --argjson baseline_score "${baseline_score}" \
  --argjson floor "${effective_floor}" \
  '(.git.head == $head or .git.head == $head_full) and .git.dirty_worktree == false and
   .score >= $floor and .decision.minimum_score == $floor and
   (.caps_applied | length) == 0 and
   .decision.hard_findings == 0 and .decision.passed == true and
   .decision.ratchet.baseline_score == $baseline_score and
   .decision.ratchet.score_delta >= 0 and
   (.decision.ratchet.new_caps | length) == 0 and
   (.decision.ratchet.new_hard_findings | length) == 0 and
   .decision.ratchet.policy_changed == false and
   .decision.ratchet.passed == true' \
  target/jankurai/repo-score.json >/dev/null
cp target/jankurai/repo-score.json .jankurai/repo-score.json
cp target/jankurai/repo-score.md .jankurai/repo-score.md

if [[ "$(git rev-parse --verify 'HEAD^{commit}')" != "${current_head}" ||
      "$(git rev-parse --verify "${BASE_REF}^{commit}")" != "${base_commit}" ||
      "$(git remote get-url origin)" != \
        'https://git.neverhuman.org/git/jeryu/jeryu-ci-runner.git' ||
      -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  printf 'proof commands changed the exact head, protected base, origin, or tracked tree\n' >&2
  exit 1
fi

proof_evidence_summary "${current_head}" "${base_commit}" "${fork_commit}" \
  "${receipt_dir}" "${#changed_paths[@]}" "${receipt_count}" \
  "${baseline_score}" "${baseline_sha256}" \
  > target/jankurai/proof-evidence-summary.json
proofmark_review="$(jq -r '.proofmark_review_obligations // "n/a"' \
  target/jankurai/proof-evidence-summary.json)"

printf 'proof evidence ok: head=%s base=%s paths=%s receipts=%s proofmark_review=%s\n' \
  "${current_head}" "${base_commit}" "${#changed_paths[@]}" \
  "${receipt_count}" "${proofmark_review}"
