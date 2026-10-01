#!/usr/bin/env bash
set -euo pipefail

# BEGIN GENERATED JANKURAI PIN — DO NOT EDIT
# The governed Jankurai identity is the binary installed on this host and its
# installation receipt: require_jankurai verifies both and exports JERYU_JANKURAI_*
# from the receipt. The one pin of record is jeryu-tool's tool-manifest.toml.
# END GENERATED JANKURAI PIN


# shellcheck source=ops/ci/hosted-git-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hosted-git-env.sh"

# Jankurai executes proof-plan commands through a login shell. Login startup
# files are allowed to reorder PATH, so resolving the auditor by name can select
# an unrelated host installation during proof replay even when the parent CI
# process put the pinned Cargo bin first. Keep every library consumer bound to
# the repository's pinned Cargo installation instead.
readonly JERYU_JANKURAI_BIN="${CARGO_HOME:-${HOME}/.cargo}/bin/jankurai"
# Jankurai 1.6.11 fingerprints the repository policy even when --fail-under
# supplies a stricter run-local threshold. Keep the fleet floor centralized so
# candidate and protected-main ratchet reports receive the identical override.
readonly JERYU_FLEET_MINIMUM_SCORE=91

audit_effective_floor() {
  local policy_path="$1"
  local configured_floor
  configured_floor="$({
    awk -F '=' '
      /^[[:space:]]*minimum_score[[:space:]]*=/ {
        count += 1
        value = $2
        sub(/[[:space:]]*#.*/, "", value)
        gsub(/[[:space:]]/, "", value)
        if (value !~ /^[0-9]+$/) exit 2
        floor = value
      }
      END {
        if (count != 1) exit 3
        print floor
      }
    ' "${policy_path}"
  })" || {
    printf 'audit policy must contain one integer minimum_score: %s\n' \
      "${policy_path}" >&2
    return 1
  }
  if (( configured_floor > JERYU_FLEET_MINIMUM_SCORE )); then
    printf '%s\n' "${configured_floor}"
  else
    printf '%s\n' "${JERYU_FLEET_MINIMUM_SCORE}"
  fi
}

validate_jankurai_binary() {
  local physical
  if [[ "${JERYU_JANKURAI_BIN}" != /* ||
        ! -f "${JERYU_JANKURAI_BIN}" ||
        -L "${JERYU_JANKURAI_BIN}" ||
        ! -x "${JERYU_JANKURAI_BIN}" ||
        "$(/usr/bin/stat -c '%h' -- "${JERYU_JANKURAI_BIN}" 2>/dev/null || true)" != 1 ]]; then
    printf 'pinned Jankurai must be an absolute executable one-link regular file: %s\n' \
      "${JERYU_JANKURAI_BIN}" >&2
    return 1
  fi
  physical="$(/usr/bin/readlink -f -- "${JERYU_JANKURAI_BIN}")" || {
    printf 'cannot resolve pinned Jankurai binary: %s\n' \
      "${JERYU_JANKURAI_BIN}" >&2
    return 1
  }
  if [[ "${physical}" != "${JERYU_JANKURAI_BIN}" ]]; then
    printf 'pinned Jankurai path is not physical: %s\n' \
      "${JERYU_JANKURAI_BIN}" >&2
    return 1
  fi
}

# Shared helpers (require_tool, require_jankurai, jankurai, security and job
# resolution) come from the pinned ci-kit copy; see ops/ci/kit.pin.
ci_kit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kit"
# shellcheck source=ops/ci/kit/lib/jankurai.sh
source "${ci_kit_dir}/lib/jankurai.sh"
# shellcheck source=ops/ci/kit/lib/security.sh
source "${ci_kit_dir}/lib/security.sh"
# shellcheck source=ops/ci/kit/lib/jobs.sh
source "${ci_kit_dir}/lib/jobs.sh"
unset ci_kit_dir

# jeryu-tool's pin renderer owns this wrapper in every ops/ci/lib.sh and
# appends it when missing, so it stays here even though the kit defines the
# same function.
jankurai() {
  require_jankurai || return 1
  command "${JERYU_GOVERNED_JANKURAI_BIN}" "$@"
}
