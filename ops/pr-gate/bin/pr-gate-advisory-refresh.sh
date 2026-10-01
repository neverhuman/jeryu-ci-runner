#!/usr/bin/env bash
# Keep ~/.cargo/advisory-db current outside the gates. Every gate's `cargo audit` fetches it under one
# lock; when the database was behind, the fetching gate held that lock for minutes and other slots
# waited up to 300s ("directory ~/.cargo/advisory-db is locked"). Refreshed here every few minutes,
# a gate's own fetch finds nothing new and releases the lock at once. It uses cargo-audit's own fetch
# and locking by auditing an empty lockfile; no gate recipe changes.
set -euo pipefail
# GATE_RUNNER_TOOLS may come from the site configuration; see pr-gate-config.sh.
# shellcheck source=ops/pr-gate/bin/pr-gate-config.sh
source "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/pr-gate-config.sh"
pr_gate_load_config
audit="${GATE_RUNNER_TOOLS:-$HOME/gate-runner/governed-tools/bin}/cargo-audit"
[[ -x "$audit" ]] || audit=$(command -v cargo-audit) || { echo "cargo-audit not found" >&2; exit 0; }
empty=$(mktemp -d); trap 'rm -rf -- "$empty"' EXIT
printf 'version = 3\n' >"$empty/Cargo.lock"
cd "$empty" && timeout 600 "$audit" audit --quiet >/dev/null
