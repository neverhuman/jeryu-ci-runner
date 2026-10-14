#!/usr/bin/env bash
# The review-controller regression suite. The suites are independent and run side by side
# (ops/ci/run-suites.sh). --list prints the suite files instead, for pr-ci.sh to run with the other
# offline suites.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
suites=()
for suite in description quality-gate draft-skip review-identity verdict-validation binary-payload credential-transport heartbeat-log heartbeat-contract model-isolation publication merge-pass held-fix-todo contributed poke installation owner-decision; do
  suites+=("$here/$suite.sh")
done
[[ "${1:-}" != --list ]] || { printf '%s\n' "${suites[@]}"; exit 0; }
exec bash "$here/../../ci/run-suites.sh" "${suites[@]}"
