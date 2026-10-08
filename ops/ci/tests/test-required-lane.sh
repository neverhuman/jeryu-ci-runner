#!/usr/bin/env bash
# Negative suite for required-lane result accounting: every non-run outcome of a
# required lane must fail, and so must a run that collected no tests. Offline;
# fixture renderers and invented site data only.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scratch_root="${repo_root}/target/required-lane-tests"
mkdir -p "${scratch_root}"
work="$(mktemp -d "${scratch_root}/run.XXXXXX")"
trap 'rm -rf -- "${work:?}"' EXIT
failures=0

pass() { printf 'ok   %s\n' "$1"; }
flunk() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
expect_ok() {
  local name="$1"; shift
  if "$@" >"${work}/out" 2>&1; then pass "${name}"; else cat "${work}/out" >&2; flunk "${name}"; fi
}
expect_fail() {
  local name="$1"; shift
  if "$@" >"${work}/out" 2>&1; then flunk "${name} (unexpected success)"; else pass "${name}"; fi
}

# shellcheck source=ops/ci/required-lane.sh
source "${repo_root}/ops/ci/required-lane.sh"

# Only an actual run is a pass.
expect_ok "a lane that ran passes" required_lane_result 'demo lane' ran
for state in skipped degraded not-run pending tool-missing; do
  expect_fail "a ${state} required lane fails" required_lane_result 'demo lane' "${state}"
done
expect_fail "an unrecognized lane result fails" required_lane_result 'demo lane' almost-ran
expect_fail "an empty lane result fails" required_lane_result 'demo lane' ''

# Test counts: zero or unreadable is not a pass.
expect_ok "a lane with tests passes" required_lane_tests_collected 'demo lane' 7
expect_fail "zero collected tests fails" required_lane_tests_collected 'demo lane' 0
expect_fail "an unreadable test count fails" required_lane_tests_collected 'demo lane' ''
expect_fail "a non-numeric test count fails" required_lane_tests_collected 'demo lane' many

# The nextest summary parser feeds that count.
printf 'Summary [   1.004s] 12 tests run: 12 passed, 0 skipped\n' >"${work}/nextest-ran.log"
printf 'Summary [   0.004s] 0 tests run: 0 passed, 0 skipped\n' >"${work}/nextest-empty.log"
printf 'error: build failed\n' >"${work}/nextest-build-failed.log"
# What nextest writes into a pipe: the summary keeps its colour codes.
printf '\033[32;1m     Summary\033[0m [   3.025s] \033[1m479\033[0m tests run: \033[1m479\033[0m \033[32;1mpassed\033[0m\n' \
  >"${work}/nextest-colour.log"
[[ "$(required_lane_nextest_count "${work}/nextest-colour.log")" == 479 ]] &&
  pass "a coloured nextest summary yields its test count" ||
  flunk "a coloured nextest summary yields its test count"
[[ "$(required_lane_nextest_count "${work}/nextest-ran.log")" == 12 ]] &&
  pass "nextest summary yields its test count" ||
  flunk "nextest summary yields its test count"
expect_fail "a zero-test nextest run fails" required_lane_tests_collected \
  'workspace test suite' "$(required_lane_nextest_count "${work}/nextest-empty.log")"
expect_fail "a nextest run with no summary fails" required_lane_tests_collected \
  'workspace test suite' "$(required_lane_nextest_count "${work}/nextest-build-failed.log")"
expect_fail "a missing nextest log fails" required_lane_tests_collected \
  'workspace test suite' "$(required_lane_nextest_count "${work}/absent.log")"

# A required lane may not stand down because its tool is absent.
tool_remedy='configure the lane tool'
printf '#!/usr/bin/env bash\nexit 0\n' >"${work}/tool.sh"
chmod +x "${work}/tool.sh"
expect_ok "an executable lane tool is accepted" \
  required_lane_tool 'demo lane' "${work}/tool.sh" "${tool_remedy}"
expect_fail "an absent lane tool fails" \
  required_lane_tool 'demo lane' "${work}/absent.sh" "${tool_remedy}"
expect_fail "an unconfigured lane tool path fails" \
  required_lane_tool 'demo lane' '' "${tool_remedy}"
printf 'not executable\n' >"${work}/plain.sh"
expect_fail "a non-executable lane tool fails" \
  required_lane_tool 'demo lane' "${work}/plain.sh" "${tool_remedy}"
mkdir -p "${work}/dir.sh"
expect_fail "a directory lane tool path fails" \
  required_lane_tool 'demo lane' "${work}/dir.sh" "${tool_remedy}"

if (( failures )); then
  printf 'required-lane suite: %d failure(s)\n' "${failures}" >&2
  exit 1
fi
printf 'required-lane suite ok\n'
