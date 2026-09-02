#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=ops/ci/hosted-git-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hosted-git-env.sh"

# Jankurai executes proof-plan commands through a login shell. Login startup
# files are allowed to reorder PATH, so resolving the auditor by name can select
# an unrelated host installation during proof replay even when the parent CI
# process put the pinned Cargo bin first. Keep every library consumer bound to
# the repository's pinned Cargo installation instead.
readonly JERYU_JANKURAI_BIN="${CARGO_HOME:-${HOME}/.cargo}/bin/jankurai"

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

require_tool() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || {
    printf 'missing required tool: %s\n' "$name" >&2
    exit 1
  }
}

require_jankurai() {
  local expected="jankurai 1.6.10"
  local actual
  validate_jankurai_binary || return 1
  actual="$(command "${JERYU_JANKURAI_BIN}" --version 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    printf 'expected %s, got %s\n' "$expected" "${actual:-missing jankurai}" >&2
    return 1
  fi
}

jankurai() {
  require_jankurai || return 1
  command "${JERYU_JANKURAI_BIN}" "$@"
}
