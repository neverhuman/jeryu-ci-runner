# Changelog

## Unreleased
- Hardened runner-wire repository identity and time ordering for the hosted
  fleet: case-sensitive repository components are preserved, expired lease
  acknowledgements fail closed, and results cannot precede their finish time.
- v5.0.0 split baseline is present on the protected hosted forge; this runner
  wire tranche remains unmerged until its governed hosted checks and review land.
- TODO: split crates/jeryu-runnerd/src/workcell.rs (1397 LOC) into
  focused submodules and restore the audit floor from 80 to 85.

## jeryu-ci-runner-v5.0.0-split.0 - 2026-06-11
- MAJOR: first standalone split-family release; the legacy monorepo
  (/home/ubuntu/jeryu) is deprecated and its drift fully reconciled.

## jeryu-ci-runner-v4.0.0-split.0

- Initial split-family baseline for `jeryu-ci-runner`.
