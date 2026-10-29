#!/usr/bin/env bash
# cargo-audit locks its fetch, but can parse after releasing that lock. Never
# parse the shared checkout: another gate or the host refresher can rewrite it.
set -euo pipefail
mkdir -p target/security
# A killed run cannot run its own trap, so drop only checkouts left by runs that
# are long gone. A day is far longer than a fetch, so this never meets a live one.
# Two gates may sweep the same stale checkout at once, so losing that race is not
# an error here; the sweep never looks at advisory data and cannot mask a finding.
find target/security -maxdepth 1 -type d -name 'advisory-db.*' -mtime +1 \
  -exec rm -rf -- {} + 2>/dev/null || true
private_db=$(mktemp -d target/security/advisory-db.XXXXXXXX)
trap 'rm -rf -- "$private_db"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Fetch directly into a new, private database. Do not copy the shared worktree
# or retry parse failures: malformed upstream data must still fail the gate.
cargo audit --db "$private_db/db" --deny warnings
