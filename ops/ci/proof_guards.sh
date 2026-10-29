#!/usr/bin/env bash
# Guards shared by the proof lane and its offline regression tests
# (ops/ci/tests/test-proof-guards.sh).

# Give this checkout the history the lane's ancestry check and its
# `git diff origin/main...HEAD` need, then refresh protected main.
#
# A depth-1 CI checkout has a grafted head: its own parents are absent. A fetch
# that names only `main` deepens main and can leave the head's graft in place,
# and then every ancestry question about the head answers "no". `--unshallow`
# with the remote's whole refspec deepens every ref the forge serves, the head's
# branch among them. A checkout still shallow after that (a head the forge does
# not serve) is refused rather than asked a question it cannot answer.
#
# The caller checks that `origin` is the hosted source repository first: this
# is the lane's only network operation against it.
proof_require_history() {
  local shallow
  shallow="$(git rev-parse --is-shallow-repository)" || return 1
  case "$shallow" in
    true)
      git fetch --quiet --no-tags --unshallow origin || return 1
      if [[ "$(git rev-parse --is-shallow-repository)" != false ]]; then
        printf 'proof checkout is still shallow after fetching every ref the forge serves\n' >&2
        return 1
      fi
      ;;
    false) ;;
    *) printf 'cannot determine proof checkout history\n' >&2; return 1 ;;
  esac
  # Refresh the protected ref explicitly: a checkout's remote-tracking main
  # may be absent or older than the main used by the forge baseline audit.
  git fetch --quiet --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
}

# Print the fork point of HEAD_COMMIT from protected main's tip BASE_COMMIT.
# The change set is judged from here, so a head behind the tip is not refused,
# and main's own head (or any ancestor of the tip) has the tip's ancestor as its
# fork point and changes nothing. Only a head with no shared history fails.
proof_fork_point() {
  local base="$1" head="$2" fork
  fork="$(git merge-base "$base" "$head")" && [[ "$fork" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'proof head shares no history with protected base: base=%s head=%s\n' \
      "$base" "$head" >&2
    return 1
  }
  printf '%s\n' "$fork"
}

# Write the NUL-separated paths HEAD_COMMIT changes since FORK_COMMIT to OUT.
# The diff goes to a file first, so a failing git diff fails the caller under
# set -e instead of leaving an empty change set behind a process substitution.
# An empty OUT is a change set of nothing, not an error.
proof_changed_paths() {
  local fork="$1" head="$2" out="$3"
  git diff --no-ext-diff --name-only -z --diff-filter=ACDMRT \
    "${fork}...${head}" >"$out.unsorted" || return 1
  LC_ALL=C sort -zu "$out.unsorted" >"$out" || return 1
  rm -f -- "$out.unsorted"
}

# Print FILE's sha256 as a JSON string; fails when FILE cannot be read.
proof_json_digest() {
  local sum
  sum="$(sha256sum -- "$1")" || return 1
  printf '"%s"\n' "${sum%% *}"
}

# Print the lane's summary, jeryu.ci-runner.proof-evidence/v2, from the
# artifacts under ./target this run wrote.
#
# Arguments: HEAD BASE FORK RECEIPT_DIR CHANGED_COUNT RECEIPT_COUNT
# BASELINE_SCORE BASELINE_SHA256.
#
# v2 over v1: adds fork_point, and admits an empty change set (changed_path_count
# 0). Then there is no proof plan, evidence index, verification, receipt
# directory or proofmark receipt, so proof_plan_sha256, evidence_index_sha256,
# proof_verification_sha256, receipt_dir and proofmark_review_obligations are
# null, receipt_count is 0 and proof_verification is "not_applicable". With a
# non-empty change set every one of them must come from a file this run wrote,
# and proof_verification is "pass". Nothing in the family reads the summary
# today; jeryu-auto-tag reads only the <repo>/required status.
proof_evidence_summary() {
  local head="$1" base="$2" fork="$3" receipt_dir="$4" changed="$5" receipts="$6"
  local baseline_score="$7" baseline_sha256="$8"
  local plan=null index=null verification=null review=null dir=null verdict=not_applicable
  [[ "$changed" =~ ^[0-9]+$ && "$receipts" =~ ^[0-9]+$ ]] || {
    printf 'proof summary counts are not whole numbers: %s %s\n' "$changed" "$receipts" >&2
    return 1
  }
  if (( changed > 0 )); then
    (( receipts > 0 )) || { printf 'a non-empty change set has no proof receipts\n' >&2; return 1; }
    plan="$(proof_json_digest target/jankurai/proof-plan.json)" || return 1
    index="$(proof_json_digest target/jankurai/evidence-index.json)" || return 1
    verification="$(proof_json_digest target/jankurai/proof-verification.json)" || return 1
    review="$(jq -er '.summary.review_obligations | numbers' \
      target/jankurai/proofmark/proofmark-receipt.json)" || return 1
    dir="$(jq -n --arg d "$receipt_dir" '$d')"
    verdict=pass
  elif (( receipts != 0 )); then
    printf 'an empty change set cannot have proof receipts\n' >&2
    return 1
  fi
  jq -n \
    --arg head "$head" --arg base "$base" --arg fork "$fork" \
    --argjson receipt_dir "$dir" \
    --argjson plan_sha256 "$plan" \
    --argjson evidence_index_sha256 "$index" \
    --argjson verification_sha256 "$verification" \
    --arg proof_verification "$verdict" \
    --argjson proofmark_review "$review" \
    --arg security_sha256 "$(sha256sum target/jankurai/security/evidence.json | awk '{print $1}')" \
    --arg supply_chain_sha256 "$(sha256sum target/security/evidence.json | awk '{print $1}')" \
    --arg sbom_sha256 "$(sha256sum target/security/sbom.cdx.json | awk '{print $1}')" \
    --arg baseline_sha256 "$baseline_sha256" \
    --argjson changed_count "$changed" \
    --argjson receipt_count "$receipts" \
    --argjson baseline_score "$baseline_score" \
    --argjson migration_liability "$(jq -er .liability_score target/jankurai/migration-report.json)" \
    --argjson baseline_migration_liability "$(jq -er .liability_score target/jankurai/baseline-migration-report.json)" \
    '{schema_version:"jeryu.ci-runner.proof-evidence/v2",git_head:$head,
      base_commit:$base,fork_point:$fork,dirty_worktree:false,changed_path_count:$changed_count,
      receipt_count:$receipt_count,receipt_dir:$receipt_dir,
      proof_plan_sha256:$plan_sha256,evidence_index_sha256:$evidence_index_sha256,
      proof_verification_sha256:$verification_sha256,security_sha256:$security_sha256,
      supply_chain_sha256:$supply_chain_sha256,sbom_sha256:$sbom_sha256,
      baseline_score:$baseline_score,baseline_sha256:$baseline_sha256,
      migration_liability_score:$migration_liability,
      baseline_migration_liability_score:$baseline_migration_liability,
      proof_verification:$proof_verification,proofmark_mode:"advisory",
      proofmark_review_obligations:$proofmark_review,
      synthetic_fallbacks:0,conclusion:"success"}'
}

# Ratchet this head's migration analysis against protected main's.
#
# Both reports are held to the same shape, the one the pinned Jankurai 1.7.5
# `jankurai migrate <root> --analyze` writes (recorded in
# ops/ci/tests/fixtures/jankurai-1.7.5-migrate-analyze.json): schema 1.0.0,
# status "complete", a non-negative numeric liability_score and an array of
# required_proof_lanes. Each is bound to the tree it analysed by source_root.
# rollback_cutover_notes is free text the tool writes and is not gated.
#
# The head may not raise liability, and may drop one of main's required proof
# lanes only when its liability is strictly lower.
proof_require_migration() {
  local baseline="$1" baseline_root="$2" candidate="$3" candidate_root="$4"
  local shape liability lanes
  shape='.schema_version == "1.0.0" and .command == "jankurai migrate" and
    .status == "complete" and .source_root == $root and
    (.liability_score | type == "number" and . >= 0) and
    (.required_proof_lanes | type == "array" and all(.[]; type == "string"))'
  jq -e --arg root "$baseline_root" "$shape" "$baseline" >/dev/null || {
    printf 'protected-main migration analysis is incomplete or not of %s\n' "$baseline_root" >&2
    return 1
  }
  jq -e --arg root "$candidate_root" "$shape" "$candidate" >/dev/null || {
    printf 'this head'"'"'s migration analysis is incomplete or not of %s\n' "$candidate_root" >&2
    return 1
  }
  liability="$(jq -er '.liability_score' "$baseline")" || return 1
  lanes="$(jq -c '.required_proof_lanes' "$baseline")" || return 1
  jq -e --argjson baseline "$liability" --argjson lanes "$lanes" '
    .liability_score <= $baseline and
    (.liability_score < $baseline or (($lanes - .required_proof_lanes) | length) == 0)
  ' "$candidate" >/dev/null || {
    printf 'migration liability regressed against protected main (liability %s, lanes %s)\n' \
      "$liability" "$lanes" >&2
    return 1
  }
}
