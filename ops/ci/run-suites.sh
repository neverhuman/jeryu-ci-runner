#!/usr/bin/env bash
# run-suites.sh SUITE... — run independent offline test suites side by side, at most JERYU_CI_JOBS
# at a time (default 4; pr-ci.sh sets it from live load), and fail if any failed.
#
# The PR gate runner suite alone took half of jeryu-ci-runner's gate, and the review-controller and
# other pr-gate suites waited behind it one by one. Each suite builds its own mktemp fixture and
# clears the gate's environment, so none depends on another or on their order. Give the longest
# first: it starts at once and the rest fill the other slots.
#
# Each suite's output is kept apart and printed whole when it ends, with its time (`[suite] <name>
# <time>`, deliberately not a gate step line), so a failure reads as it would run alone.
set -euo pipefail
(($#)) || { printf 'usage: run-suites.sh SUITE...\n' >&2; exit 2; }
jobs=${JERYU_CI_JOBS:-4}
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { printf 'JERYU_CI_JOBS must be a positive integer: %s\n' "$jobs" >&2; exit 2; }
out=$(mktemp -d)
trap 'rm -rf -- "$out"' EXIT
declare -A index_of=()
names=() started=() failed=()

reap() { # wait for one running suite, then print it whole and record its result
  local pid status=0 i
  wait -n -p pid "${!index_of[@]}" || status=$?
  i=${index_of[$pid]}
  unset 'index_of[$pid]'
  cat -- "$out/$i.log"
  printf '[suite] %s %ss%s\n' "${names[$i]}" "$(($(date +%s) - started[i]))" \
    "$( ((status == 0)) || printf ' FAILED (exit %d)' "$status")"
  ((status == 0)) || failed+=("${names[$i]}")
}

for suite in "$@"; do
  [[ -f "$suite" ]] || { printf 'no such suite: %s\n' "$suite" >&2; failed+=("$suite"); continue; }
  while ((${#index_of[@]} >= jobs)); do reap; done
  i=${#names[@]}
  names+=("$suite") started+=("$(date +%s)")
  bash "$suite" >"$out/$i.log" 2>&1 </dev/null &
  index_of[$!]=$i
done
while ((${#index_of[@]})); do reap; done

if ((${#failed[@]})); then
  printf 'FAILED suites: %s\n' "${failed[*]}" >&2
  exit 1
fi
