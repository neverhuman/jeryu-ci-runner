#!/usr/bin/env bash
# cargo-audit locks its fetch, but can parse after releasing that lock. Never
# parse the shared checkout: another gate or the host refresher can rewrite it.
set -euo pipefail
mkdir -p target/security
private_db=$(mktemp -d target/security/advisory-db.XXXXXXXX)
trap 'rm -rf -- "$private_db"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Fetch directly into a new, private database. Do not copy the shared worktree
# or retry parse failures: malformed upstream data must still fail the gate.
cargo audit --db "$private_db/db" --deny warnings
