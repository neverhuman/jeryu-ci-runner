set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

jobs := env_var_or_default("JERYU_CI_JOBS", "40")

fast:
  ./ops/ci/fast.sh # cargo check

check:
  ./ops/ci/check.sh

score:
  ./ops/ci/score.sh # jankurai audit repo-score

security:
  JERYU_SECURITY_NETWORK=1 ./tools/security-lane.sh

# Narrow per-package lanes for fast agent iteration (nextest runs tests in parallel processes).
test-sandbox:
  cargo nextest run -p jeryu-sandbox-linux --locked

test-native:
  cargo nextest run -p jeryu-runner-native --locked

contract-drift:
  cargo test -p jeryu-runner-protocol --locked --test schema_contract_drift

artifact-support:
  ./ops/ci/artifact_support.sh

profile:
  printf '%s\n' "rust-workspace"

# Entry point for the protected jeryu-ci-runner/required check: the existing lane, unchanged.
required:
  bash ops/ci/pr-ci.sh
