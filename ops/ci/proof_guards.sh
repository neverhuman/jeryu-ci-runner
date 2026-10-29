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
    "${fork}...${head}" >"$out"
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
