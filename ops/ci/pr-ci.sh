#!/usr/bin/env bash
# Canonical local PR gate for jeryu-ci-runner. host-ci prefers this script and posts the
# `jeryu-ci-runner/required` check-run from its exit status; .github/workflows/ci.yml runs
# the same lanes on the GitHub mirror so the two surfaces cannot diverge.
set -euo pipefail

# BEGIN GENERATED JANKURAI PIN — DO NOT EDIT
# The governed Jankurai identity is the binary installed on this host and its
# installation receipt: require_jankurai verifies both and exports JERYU_JANKURAI_*
# from the receipt. The one pin of record is jeryu-tool's tool-manifest.toml.
# END GENERATED JANKURAI PIN

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

# Resolve and verify the absolute governed auditor before any lane runs.
source ops/ci/lib.sh
# shellcheck source=ops/ci/required-lane.sh
source ops/ci/required-lane.sh
require_jankurai
# shellcheck source=ops/ci/hosted-git-env.sh
source "${repo_root}/ops/ci/hosted-git-env.sh"

# jeryu governs the worker count from live load; never default high.
ci_kit_resolve_jobs
JOBS="${JERYU_CI_JOBS}"

# The pinned Jankurai 1.7.5 lives in ~/.cargo/bin. Other host installations
# may appear earlier on PATH, so resolve the pinned auditor first; scripts that
# source lib.sh additionally invoke its physical path so login-shell proof
# replay cannot change audit semantics (see ops/ci/ensure-jankurai.sh).

# jankurai pin: jeryu-tool/tool-manifest.toml is the family-wide source of truth.
# When the control-plane repo is reachable (on-host family layout), fail fast if
# this repo's pinned consumers drifted from it. In an isolated single-repo CI
# checkout it is absent — skip rather than fail.
JERYU_TOOL_RENDER="${JERYU_TOOL_RENDER:-$repo_root/../jeryu-tool/ops/render-tool-manifest.sh}"
if [ -x "$JERYU_TOOL_RENDER" ]; then
  echo "[pr-ci] jankurai pin drift check" >&2
  consumer_repo="$(awk -F'\"' '/^workspace =/ {print $2; exit}' agent/audit-policy.toml)"
bash "$JERYU_TOOL_RENDER" --check --repo "$consumer_repo" \
--repo-root "$consumer_repo=$repo_root"
fi

# One pool, so the review-controller suites run beside the long PR gate runner suite instead of
# after it. Each suite's own time is in the log as `[suite] <file> <time>`.
echo "[pr-ci] offline regression suites (PR gate runner + review controller)" >&2
bash ops/ci/run-suites.sh --list ops/pr-gate/tests/required.sh ops/pr-redteam/test/required.sh

# Ordinary compilation -- cargo check, the contract-drift tests, the workspace test build and the
# sandbox matrix's static cargo test/run -- builds in the gate runner's retained per-slot cache when
# the gate host offers one (JERYU_CI_BUILD_CACHE_DIR; ops/pr-gate/README.md, "Reusing ordinary
# compilation without retaining proof"). This recipe measures nothing from a build directory: there
# is no coverage or profile build, and every report it writes (.jankurai/, target/jankurai/,
# target/security/, target/artifact-support/) names target/ literally, so it stays outside the
# cache. The runner retains the cache only after a green gate and discards it when tools, recipe or
# Cargo.lock change; cargo still checks every source file's freshness. Unset (a laptop, another
# host), cargo builds into target/ as before.
# BEGIN BUILD CACHE GUARD
if [ -n "${JERYU_CI_BUILD_CACHE_DIR:-}" ]; then
  # Accept only this checkout's own physical target/build-cache, owned by this user (the layout the
  # gate runner gives), never a symlink or a path elsewhere; and never reuse incremental state.
  cache_dir="$JERYU_CI_BUILD_CACHE_DIR"
  cache_top="$repo_root"
  if [[ -L "$cache_top/target" || -L "$cache_dir" || ! -d "$cache_dir" || ! -O "$cache_dir" \
        || "$(cd "$cache_dir" && pwd -P)" != "$(cd "$cache_top" && pwd -P)/target/build-cache" ]]; then
    echo "refusing JERYU_CI_BUILD_CACHE_DIR=$cache_dir: only this checkout's physical target/build-cache is accepted" >&2
    exit 1
  fi
  CARGO_TARGET_DIR="$(cd "$cache_dir" && pwd -P)"
  export CARGO_TARGET_DIR CARGO_INCREMENTAL=0
  echo "[pr-ci] ordinary compilation in ${CARGO_TARGET_DIR} (the gate runner's build cache)" >&2
fi
# END BUILD CACHE GUARD

echo "[pr-ci] (jobs=$JOBS) standard lanes" >&2
JERYU_SPLIT_FULL_CHECK=1 bash ops/ci/check.sh
just contract-drift
bash ops/ci/score.sh
# The pre-approval gate: the verdict the hosted jankurai/proof will publish for
# this head, before the PR exists. Refuses only where the rollout is on
# (agent/jankurai-gate.toml); elsewhere it reports and passes.
bash ops/ci/jankurai-gate.sh
JERYU_SECURITY_NETWORK=1 bash ops/ci/security.sh
bash ops/ci/artifact_support.sh

echo "[pr-ci] workspace test suite (sandbox runtime tests need real namespaces; see deploy pr-ci precedent)" >&2
test_log="$(mktemp "${TMPDIR:-/tmp}/jeryu-ci-runner-nextest.XXXXXX")"
trap 'rm -f -- "$test_log"' EXIT
cargo nextest run --profile ci --locked --workspace --exclude jeryu-sandbox-linux --build-jobs "$JOBS" --test-threads "$JOBS" 2>&1 | tee "$test_log"
# A green exit with no tests collected is not a pass for a required lane.
required_lane_tests_collected "workspace test suite" \
  "$(required_lane_nextest_count "$test_log")"
# Required lane: the matrix needs docker, and a host without it fails the check
# rather than standing the lane down.
if [ "${JERYU_SKIP_SANDBOX_MATRIX:-0}" = "1" ]; then
  required_lane_result "sandbox escape matrix" skipped \
    'JERYU_SKIP_SANDBOX_MATRIX is set; the required check has to run this lane'
fi
echo "[pr-ci] sandbox escape matrix (docker)" >&2
bash tests/sandbox_escape_matrix.sh
required_lane_result "sandbox escape matrix" ran
# Last, after the test suite and the sandbox matrix, so a forge or network
# failure in this lane is reported as its own failure and hides no test result.
# It needs a clean exact head whose origin is the hosted repository, the network
# and the forge, and a head descending from protected main (docs/testing.md).
echo "[pr-ci] proof evidence lane (ratchet against the forge's protected main)" >&2
bash ops/ci/proof_evidence.sh
echo "[pr-ci] jeryu-ci-runner OK" >&2
