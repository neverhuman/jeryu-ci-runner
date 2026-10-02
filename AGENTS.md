# jeryu-ci-runner Agent Instructions

This is a Jeryu split repository seeded from `cbecf7caa0e932c76a341b2521e66e911233860d`.

Before editing, read `README.md`, `agent/owner-map.json`,
`agent/test-map.json`, `agent/generated-zones.toml`,
`agent/proof-lanes.toml`, `agent/audit-policy.toml`, and
`agent/boundaries.toml`.

Keep split `main` clean. The legacy monorepo is
deprecated and archived as `jeryu/jeryu-monorepo`; this split family is the
only source of truth. Land changes through PRs with green required checks.

Cross-repo Rust dependencies retain their immutable Cargo source identities and
are pinned to exact v5 split tags. Host CI must source
`ops/ci/hosted-git-env.sh`; `.cargo/hosted-gitconfig` then maps only the
authenticated dependency URL to `git.neverhuman.org`. Do not rewrite the Cargo
source spelling or add local sibling path patches, because either can create a
second crate identity.

The public runner wire mirror is `schemas/jeryu.runner.v1.schema.json`. Rust
serde plus `ValidateWire` remain authoritative; run `just contract-drift` whenever
wire source or schema bytes change.

## Test placement

One rule for this repository: a test lives in the crate that owns the code it
exercises, and in exactly one place.

- Unit tests (private items, single module) go in that module's
  `#[cfg(test)] mod tests`; move them to a sibling `src/<module>/tests.rs` via
  `mod tests;` once the inline block outgrows the module. Never both.
- Tests that drive only a crate's public API go in that crate's
  `crates/<crate>/tests/*.rs` (or `bins/<bin>/tests/`).
- The repository-level `tests/` holds only shared fixtures and shell matrices
  (`tests/fixtures/`, `tests/sandbox_escape_matrix.sh`), never Rust tests.

Before adding a test, search both the module and the crate's `tests/` for an
existing case covering the same behavior; extend it rather than duplicating it.
The jankurai pin lives only in the generated block of `ops/ci/ensure-jankurai.sh`
(currently `jankurai 1.6.11`, matching jeryu-core); `just required` is the entry
point for the protected required check.
Shared CI helpers live in the versioned `ops/ci-kit/` (see its README), which
this repo and the rest of the family vendor as `ops/ci/kit/` pinned by
`ops/ci/kit.pin`. Never edit a vendored copy: change the kit, bump its
`VERSION`, run `ops/ci-kit/bin/seal.sh`, then `ops/ci-kit/bin/vendor.sh .`.
