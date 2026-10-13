#!/usr/bin/env bash
# The required check's own wiring: every CI entry script lane it names must be
# unconditional, so no lane can be reintroduced behind an "only if the tool is
# here" guard.
#
# One block is exempt by name: the jankurai pin drift check that jeryu-tool
# renders into pr-ci.sh (from `JERYU_TOOL_RENDER=` to its `fi`). It is generated,
# so it cannot be changed here; making it fail closed is a jeryu-tool template
# change. Every other conditional lane is a failure.
#
# This is a tripwire over entry scripts, not a proof: it reads lines, not a
# shell AST.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
pr_ci="${repo_root}/ops/ci/pr-ci.sh"
check_sh="${repo_root}/ops/ci/check.sh"
entry_scripts=(
  "${repo_root}/ops/ci/pr-ci.sh"
  "${repo_root}/ops/ci/fast.sh"
  "${repo_root}/ops/ci/check.sh"
  "${repo_root}/ops/ci/score.sh"
  "${repo_root}/ops/ci/security.sh"
  "${repo_root}/ops/ci/artifact_support.sh"
  "${repo_root}/ops/ci/jankurai-gate.sh"
  "${repo_root}/tools/security-lane.sh"
  "${repo_root}/ops/ci/proof_evidence.sh"
  "${repo_root}/ops/ci/dependency-sources.sh"
  "${repo_root}/ops/ci/ensure-jankurai.sh"
  "${repo_root}/ops/ci/lib.sh"
)
failures=0
pass() { printf 'ok   %s\n' "$1"; }
flunk() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

# guarded_lanes <script>: print every lane invocation (bash/just/cargo) that
# sits inside a multi-line if/case, or behind `then`, `&&` or `||` on one line.
guarded_lanes() {
  awk -v check_sh="${check_sh}" '
    function is_lane_command(line) {
      return line ~ /^[[:space:]]*(bash|just|cargo|actionlint|jankurai|syft)[[:space:]]/
    }
    function has_guarded_lane(line) {
      return line ~ /(then|&&|\|\|)[[:space:]]*(bash|just|cargo|actionlint|jankurai|syft)[[:space:]]/
    }
    FNR == 1 { depth = 0; generated = 0; full_check_depth = 0 }
    /^JERYU_TOOL_RENDER=/ { generated = 1 }
    generated { if ($0 ~ /^fi[[:space:]]*$/) generated = 0; next }
    # check.sh gates its expensive full-check command by JERYU_SPLIT_FULL_CHECK;
    # that is the only conditional cargo-check exemption.
    FILENAME == check_sh && full_check_depth > 0 &&
      /^[[:space:]]*cargo check --locked --workspace --all-targets/ { next }
    has_guarded_lane($0) { print FILENAME ":" FNR ":" $0; next }
    /^[[:space:]]*(if|case)[[:space:]]/ && !/;[[:space:]]*(fi|esac)[[:space:]]*$/ {
      depth += 1
      if (FILENAME == check_sh && $0 ~ /JERYU_SPLIT_FULL_CHECK/) full_check_depth = depth
      next
    }
    /^[[:space:]]*(fi|esac)[[:space:]]*$/ {
      if (depth > 0 && depth == full_check_depth) full_check_depth = 0
      if (depth > 0) depth -= 1
      next
    }
    depth > 0 && is_lane_command($0) { print FILENAME ":" FNR ":" $0 }
  ' "$@"
}

mapfile -t guarded < <(guarded_lanes "${entry_scripts[@]}")
if (( ${#guarded[@]} == 0 )); then
  pass "no CI entry script lane is conditionally invoked"
else
  printf '%s\n' "${guarded[@]}" >&2
  flunk "no CI entry script lane is conditionally invoked"
fi

# The detector itself: each conditional shape is caught, an if/elif chain does
# not leave the depth raised for the lanes after it, and the generated block is
# the only exemption.
fixture="$(mktemp)"
trap 'rm -f -- "${fixture}"' EXIT
cat >"${fixture}" <<'FIXTURE'
if [ -x "$A" ]; then
  bash ops/ci/multi-line.sh
elif [ -x "$B" ]; then
  true
fi
bash ops/ci/after-elif.sh
if [ -x "$C" ]; then bash ops/ci/one-line.sh; fi
[ -x "$D" ] && bash ops/ci/and-guard.sh
JERYU_TOOL_RENDER="${JERYU_TOOL_RENDER:-x}"
if [ -x "$JERYU_TOOL_RENDER" ]; then
  bash "$JERYU_TOOL_RENDER" --check
fi
bash ops/ci/after-generated.sh
FIXTURE
mapfile -t caught < <(guarded_lanes "${fixture}")
expected=$"${fixture}"':2:  bash ops/ci/multi-line.sh
'"${fixture}"':7:if [ -x "$C" ]; then bash ops/ci/one-line.sh; fi
'"${fixture}"':8:[ -x "$D" ] && bash ops/ci/and-guard.sh'
actual="$(printf '%s\n' "${caught[@]}")"
if [[ "${actual}" == "${expected}" ]]; then
  pass "the wiring detector catches each conditional shape and nothing else"
else
  printf '%s\n' "${caught[@]}" >&2
  flunk "the wiring detector catches each conditional shape and nothing else"
fi

cat >"${fixture}" <<'FIXTURE'
if [[ "${JERYU_SPLIT_FULL_CHECK:-0}" == "1" ]]; then
  cargo check --locked --workspace --all-targets
fi
FIXTURE
mapfile -t caught < <(guarded_lanes "${fixture}")
if (( ${#caught[@]} == 1 )); then
  pass "cargo check exemption is scoped to check.sh"
else
  flunk "cargo check exemption is scoped to check.sh"
fi

grep -q 'required_lane_result "sandbox escape matrix" skipped' "${pr_ci}" &&
  pass "standing down the sandbox escape matrix fails the check" ||
  flunk "standing down the sandbox escape matrix fails the check"

grep -q 'required_lane_tests_collected "workspace test suite"' "${pr_ci}" &&
  pass "the workspace test suite accounts for its test count" ||
  flunk "the workspace test suite accounts for its test count"

# pr-ci.sh runs check.sh exactly once, so this suite runs once per gate, from
# check.sh.
grep -q '^bash ops/ci/tests/required.sh$' "${check_sh}" &&
  grep -q '^JERYU_SPLIT_FULL_CHECK=1 bash ops/ci/check.sh$' "${pr_ci}" &&
  grep -q '^\./ops/ci/check.sh$' "${repo_root}/ops/ci/fast.sh" &&
  pass "the required check runs this suite" ||
  flunk "the required check runs this suite"

check_count="$(
  grep -Ec '(^|[[:space:]])(bash[[:space:]]+)?(\./)?ops/ci/check\.sh([[:space:]]|$)' "${pr_ci}"
)"
fast_count="$(
  grep -Ec '(^|[[:space:]])(bash[[:space:]]+)?(\./)?ops/ci/check\.sh([[:space:]]|$)' "${repo_root}/ops/ci/fast.sh"
)"
if [[ "${check_count}" == 1 && "${fast_count}" == 1 ]]; then
  pass "pr-ci runs check.sh once"
else
  flunk "pr-ci runs check.sh once"
fi

if (( failures )); then
  printf 'pr-ci lane wiring: %d failure(s)\n' "${failures}" >&2
  exit 1
fi
printf 'pr-ci lane wiring ok\n'
