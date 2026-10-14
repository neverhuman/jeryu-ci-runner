#!/usr/bin/env bash
# The pr-gate regression suite: offline, fixture forges and invented site data only. The suites are
# independent and run side by side (ops/ci/run-suites.sh); runner, the longest, starts first.
# --list prints the suite files instead, for pr-ci.sh to run with the other offline suites.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
suites=()
for suite in runner config state progress contributed namespace locks heartbeat wake audit backoff retention prefetch gitcred install grype-db-refresh; do
  suites+=("$here/test-pr-gate-$suite.sh")
done
[[ "${1:-}" != --list ]] || { printf '%s\n' "${suites[@]}"; exit 0; }
exec bash "$here/../../ci/run-suites.sh" "${suites[@]}"
