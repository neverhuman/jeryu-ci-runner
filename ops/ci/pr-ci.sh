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
require_jankurai
# shellcheck source=ops/ci/hosted-git-env.sh
source "${repo_root}/ops/ci/hosted-git-env.sh"

# jeryu governs the worker count from live load; never default high.
ci_kit_resolve_jobs
JOBS="${JERYU_CI_JOBS}"

# The pinned Jankurai 1.6.11 lives in ~/.cargo/bin. Other host installations
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

echo "[pr-ci] offline review-controller regression suite" >&2
bash ops/pr-redteam/test/required.sh

echo "[pr-ci] offline PR gate runner regression suite" >&2
bash ops/pr-gate/tests/required.sh

echo "[pr-ci] (jobs=$JOBS) standard lanes" >&2
bash ops/ci/fast.sh
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
cargo nextest run --profile ci --locked --workspace --exclude jeryu-sandbox-linux --build-jobs "$JOBS" --test-threads "$JOBS"
if [ "${JERYU_SKIP_SANDBOX_MATRIX:-0}" != "1" ]; then
  echo "[pr-ci] sandbox escape matrix (docker)" >&2
  bash tests/sandbox_escape_matrix.sh
fi
echo "[pr-ci] jeryu-ci-runner OK" >&2
