#!/usr/bin/env bash
# Keep grype's vulnerability database current outside the gates. Gate recipes run the governed grype,
# which refuses a database older than its max allowed age ("the vulnerability database was built
# 7 weeks ago (max allowed age is 5 days)") and fails the gate. The database lives in grype's own
# cache (GRYPE_DB_CACHE_DIR, default ~/.cache/grype/db); refreshed here every few hours with grype's
# own `db update`, which downloads only when a newer build is listed. Gates never fetch it themselves.
set -euo pipefail
# GATE_RUNNER_TOOLS may come from the site configuration; see pr-gate-config.sh.
# shellcheck source=ops/pr-gate/bin/pr-gate-config.sh
source "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/pr-gate-config.sh"
pr_gate_load_config
grype="${GATE_RUNNER_TOOLS:-$HOME/gate-runner/governed-tools/bin}/grype"
[[ -x "$grype" ]] || grype=$(command -v grype) || { echo "grype not found" >&2; exit 0; }
timeout 1200 "$grype" db update --quiet >/dev/null
