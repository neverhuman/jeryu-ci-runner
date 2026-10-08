#!/usr/bin/env bash
# The required check's own wiring: every lane it names must be unconditional,
# so no lane can be reintroduced behind an "only if the tool is here" guard.
#
# One block is exempt by name: the jankurai pin drift check that jeryu-tool
# renders into pr-ci.sh (from `JERYU_TOOL_RENDER=` to its `fi`). It is generated,
# so it cannot be changed here; making it fail closed is a jeryu-tool template
# change. Every other conditional lane is a failure.
#
# This is a tripwire over pr-ci.sh, not a proof: it reads lines, not a shell AST.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
pr_ci="${repo_root}/ops/ci/pr-ci.sh"
check_sh="${repo_root}/ops/ci/check.sh"
failures=0
pass() { printf 'ok   %s\n' "$1"; }
flunk() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

# guarded_lanes <script>: print every lane invocation (bash/just/cargo) that
# sits inside a multi-line if/case, or behind `then`, `&&` or `||` on one line.
guarded_lanes() {
  awk '
    /^JERYU_TOOL_RENDER=/ { generated = 1 }
    generated { if ($0 ~ /^fi[[:space:]]*$/) generated = 0; next }
    /(then|&&|\|\|)[[:space:]]*(bash|just|cargo)[[:space:]]/ { print; next }
    /^[[:space:]]*(if|case)[[:space:]]/ && !/;[[:space:]]*(fi|esac)[[:space:]]*$/ { depth += 1; next }
    /^[[:space:]]*(fi|esac)[[:space:]]*$/ { if (depth > 0) depth -= 1; next }
    depth > 0 && /^[[:space:]]*(bash|just|cargo)[[:space:]]/ { print }
  ' "$1"
}

mapfile -t guarded < <(guarded_lanes "${pr_ci}")
if (( ${#guarded[@]} == 0 )); then
  pass "no lane is conditionally invoked"
else
  printf '%s\n' "${guarded[@]}" >&2
  flunk "no lane is conditionally invoked"
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
expected=$'  bash ops/ci/multi-line.sh\nif [ -x "$C" ]; then bash ops/ci/one-line.sh; fi\n[ -x "$D" ] && bash ops/ci/and-guard.sh'
if [[ "$(printf '%s\n' "${caught[@]}")" == "${expected}" ]]; then
  pass "the wiring detector catches each conditional shape and nothing else"
else
  printf '%s\n' "${caught[@]}" >&2
  flunk "the wiring detector catches each conditional shape and nothing else"
fi

grep -q 'required_lane_result "sandbox escape matrix" skipped' "${pr_ci}" &&
  pass "standing down the sandbox escape matrix fails the check" ||
  flunk "standing down the sandbox escape matrix fails the check"

grep -q 'required_lane_tests_collected "workspace test suite"' "${pr_ci}" &&
  pass "the workspace test suite accounts for its test count" ||
  flunk "the workspace test suite accounts for its test count"

# pr-ci.sh runs check.sh, so the suite runs once per gate, from check.sh.
grep -q '^bash ops/ci/tests/required.sh$' "${check_sh}" &&
  grep -q '^JERYU_SPLIT_FULL_CHECK=1 bash ops/ci/check.sh$' "${pr_ci}" &&
  pass "the required check runs this suite" ||
  flunk "the required check runs this suite"

if (( failures )); then
  printf 'pr-ci lane wiring: %d failure(s)\n' "${failures}" >&2
  exit 1
fi
printf 'pr-ci lane wiring ok\n'
