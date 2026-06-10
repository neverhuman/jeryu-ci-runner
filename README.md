# jeryu-ci-runner

CI IR, scheduler, runner fabric, workcells, sandboxing, agent execution substrate.

This repository was seeded from Jeryu source commit `cbecf7caa0e932c76a341b2521e66e911233860d` by
`ops/split/materialize.py`. It is part of the seven-repo Jeryu split family and keeps source
paths stable where practical so ownership remains auditable.

## Owned Cargo Packages

- `crates/jeryu-ci-ir`
- `crates/jeryu-ci-compiler`
- `crates/jeryu-ci-scheduler`
- `crates/jeryu-runner-core`
- `crates/jeryu-runner-native`
- `crates/jeryu-runner-microvm`
- `crates/jeryu-runner-oci`
- `crates/jeryu-runner-protocol`
- `crates/jeryu-runner-registry`
- `crates/jeryu-runnerd`
- `crates/jeryu-sandbox-linux`
- `crates/jeryu-agentbridge`
- `crates/jeryu-agent-auth`
- `crates/jeryu-agent-stream`
- `crates/jeryu-egress`
- `crates/jeryu-artifact-metadata`
- `crates/jeryu-cache-policy`
- `crates/jeryu-ci-governor`
- `crates/jeryu-phase7-cli`
- `bins/jeryu-ci-bin`

## Source Coverage

- `crates/jeryu-ci-ir/**`
- `crates/jeryu-ci-compiler/**`
- `crates/jeryu-ci-scheduler/**`
- `crates/jeryu-runner-core/**`
- `crates/jeryu-runner-native/**`
- `crates/jeryu-runner-microvm/**`
- `crates/jeryu-runner-oci/**`
- `crates/jeryu-runner-protocol/**`
- `crates/jeryu-runner-registry/**`
- `crates/jeryu-runnerd/**`
- `crates/jeryu-sandbox-linux/**`
- `crates/jeryu-agentbridge/**`
- `crates/jeryu-agent-auth/**`
- `crates/jeryu-agent-stream/**`
- `crates/jeryu-egress/**`
- `crates/jeryu-artifact-metadata/**`
- `crates/jeryu-cache-policy/**`
- `crates/jeryu-ci-governor/**`
- `crates/jeryu-phase7-cli/**`
- `bins/jeryu-ci-bin/**`
- `tests/fixtures/github/**`
- `tests/fixtures/native/**`
- `tests/sandbox_escape_matrix.sh`
- `examples/jobs/**`
- `ops/agent-sandbox/**`
- `images/agent-sandbox/**`
- `policies/**`
- `configs/runnerd.toml`

## Local Commands

- `just fast`
- `just check`
- `just score`
- `just security`
- `just artifact-support`
