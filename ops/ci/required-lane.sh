#!/usr/bin/env bash
# Result accounting for the lanes behind the protected `jeryu-ci-runner/required`
# check. A required lane passes only when it actually ran: any other outcome
# (skipped, degraded, not-run, pending, tool-missing) and any run that collected
# zero tests is a failure, so the published check can never be greener than the
# work that was done.
set -euo pipefail

# The only outcome a required lane may report.
readonly REQUIRED_LANE_RAN='ran'

# required_lane_result <lane> <status> [detail]
required_lane_result() {
  local lane="$1" status="$2" detail="${3:-}"
  case "${status}" in
    "${REQUIRED_LANE_RAN}")
      printf '[required-lane] %s ran\n' "${lane}" >&2
      return 0
      ;;
    skipped|degraded|not-run|pending|tool-missing)
      ;;
    *)
      detail="unrecognized lane result '${status}'${detail:+: ${detail}}"
      status='not-run'
      ;;
  esac
  printf '[required-lane] %s is required and did not run (%s)%s\n' \
    "${lane}" "${status}" "${detail:+: ${detail}}" >&2
  return 1
}

# required_lane_tool <lane> <path> <how-to-provide>
# A required lane may not stand down because its tool is absent: the site
# supplies the path (see the lane's environment variable) and the lane fails
# when that path is not an executable file.
required_lane_tool() {
  local lane="$1" path="$2" remedy="$3"
  if [[ -z "${path}" ]]; then
    required_lane_result "${lane}" tool-missing "no tool path configured; ${remedy}"
    return 1
  fi
  if [[ -d "${path}" || ! -f "${path}" || ! -x "${path}" ]]; then
    required_lane_result "${lane}" tool-missing \
      "${path} is not an executable file; ${remedy}"
    return 1
  fi
}

# required_lane_tests_collected <lane> <count>
required_lane_tests_collected() {
  local lane="$1" count="${2:-}"
  if [[ ! "${count}" =~ ^[0-9]+$ ]]; then
    required_lane_result "${lane}" not-run \
      "could not read a test count from the lane output"
    return 1
  fi
  if (( count == 0 )); then
    required_lane_result "${lane}" not-run "the lane collected zero tests"
    return 1
  fi
  required_lane_result "${lane}" "${REQUIRED_LANE_RAN}" || return 1
  printf '[required-lane] %s collected %s tests\n' "${lane}" "${count}" >&2
}

# required_lane_nextest_count <log>
# Prints the number of tests nextest reported as run, or nothing when its
# summary line is absent (a build that never reached the tests, for instance).
# nextest colours its summary even into a pipe, so ANSI SGR codes are stripped
# before the line is read.
required_lane_nextest_count() {
  local log="$1"
  [[ -f "${log}" ]] || return 0
  sed -e 's/\x1b\[[0-9;]*m//g' "${log}" |
    sed -n 's/^[[:space:]]*Summary \[[^]]*\] *\([0-9]\+\) tests\? run.*/\1/p' |
    tail -n 1
}
