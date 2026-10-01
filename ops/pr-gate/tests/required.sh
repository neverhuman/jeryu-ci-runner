#!/usr/bin/env bash
# The pr-gate regression suite: offline, fixture forges and invented site data only.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for suite in config state runner namespace locks heartbeat wake retention prefetch install grype-db-refresh; do
  bash "$here/test-pr-gate-$suite.sh"
done
