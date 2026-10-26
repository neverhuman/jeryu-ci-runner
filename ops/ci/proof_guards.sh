#!/usr/bin/env bash
# Guards shared by the proof lane and its offline regression tests.
proof_require_history() {
  local shallow
  shallow="$(git rev-parse --is-shallow-repository)" || return 1
  case "$shallow" in
    true) git fetch --quiet --no-tags --unshallow origin main || return 1 ;;
    false) ;;
    *) printf 'cannot determine proof checkout history\n' >&2; return 1 ;;
  esac
  # Refresh the protected ref explicitly: a checkout's remote-tracking main
  # may be absent or older than the main used by the forge baseline audit.
  git fetch --quiet --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
}

proof_require_migration() {
  local baseline="$1" candidate="$2" liability
  liability="$(jq -er '
    select(.schema_version == "1.0.0" and .status == "complete") |
    .liability_score | select(type == "number" and . >= 0)
  ' "$baseline")" || return 1
  jq -e --argjson baseline "$liability" '
    .schema_version == "1.0.0" and .status == "complete" and
    (.liability_score | type == "number" and . >= 0 and . <= $baseline) and
    (.required_proof_lanes | type == "array") and
    (.rollback_cutover_notes | type == "array" and length > 0)
  ' "$candidate" >/dev/null
}
