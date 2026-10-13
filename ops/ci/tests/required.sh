#!/usr/bin/env bash
# The ops/ci regression suite: offline, invented site data only.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for suite in required-lane pr-ci-lanes helper-scope; do
  bash "$here/test-$suite.sh"
done
