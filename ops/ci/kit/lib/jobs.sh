#!/usr/bin/env bash
# jeryu ci-kit: CI worker-count resolution shared by every family repo.
# Source-only. Canonical source: jeryu-ci-runner ops/ci-kit/.

# jeryu governs the worker count from live load; never default high.
# Exports JERYU_CI_JOBS and (unless already set) CARGO_BUILD_JOBS.
ci_kit_resolve_jobs() {
  local jobs
  if [[ -n "${JERYU_CI_JOBS:-}" ]]; then
    jobs="${JERYU_CI_JOBS}"
  elif command -v jeryu-ci-governor >/dev/null 2>&1; then
    jobs="$(jeryu-ci-governor 2>/dev/null || echo 8)"
  else
    jobs=8
  fi
  if [[ ! "${jobs}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'CI job count must be a positive integer: %s\n' "${jobs}" >&2
    return 1
  fi
  export JERYU_CI_JOBS="${jobs}"
  export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-${jobs}}"
}
