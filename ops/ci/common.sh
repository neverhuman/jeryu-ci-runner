#!/usr/bin/env bash
# Shared local CI defaults for this split repo. Keep this file source-only.
set -euo pipefail

# shellcheck source=ops/ci/hosted-git-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hosted-git-env.sh"

JERYU_CI_JOBS="${JERYU_CI_JOBS:-8}"
export JERYU_CI_JOBS
