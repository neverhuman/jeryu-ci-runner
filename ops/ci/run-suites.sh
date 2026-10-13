#!/usr/bin/env bash
# run-suites.sh SUITE... — run independent offline test suites side by side.
# --list PRODUCER... discovers every family first, refusing failed or empty lists before dispatch.
# JERYU_CI_SUITE_JOBS sets the pool size (default 2, range 1–4), independently of Cargo workers.
#
# The PR gate runner suite alone took half of jeryu-ci-runner's gate, and the review-controller and
# other pr-gate suites waited behind it one by one. Each suite builds its own mktemp fixture and
# clears the gate's environment, so none depends on another or on their order. Give the longest
# first: it starts at once and the rest fill the other slots.
#
# Each suite's output is kept apart and printed whole when it ends, with its time (`[suite] <name>
# <time>`, deliberately not a gate step line), so a failure reads as it would run alone.
set -euo pipefail
(($#)) || { printf 'usage: run-suites.sh SUITE... | --list PRODUCER...\n' >&2; exit 2; }
((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1))) || {
  printf 'run-suites.sh requires Bash 5.1 or newer (wait -n -p)\n' >&2; exit 2;
}
jobs=${JERYU_CI_SUITE_JOBS:-2}
[[ "$jobs" =~ ^[1-4]$ ]] || {
  printf 'JERYU_CI_SUITE_JOBS must be an integer from 1 to 4: %s\n' "$jobs" >&2; exit 2;
}

if [[ "$1" == --list ]]; then
  shift
  (($#)) || { printf 'run-suites.sh --list requires a producer\n' >&2; exit 2; }
  suites=()
  declare -A discovered=()
  for producer in "$@"; do
    status=0
    listed=$(bash "$producer" --list) || status=$?
    if ((status != 0)) || [[ -z "$listed" ]]; then
      printf 'FAILED suite list: %s (exit %d; empty lists are refused)\n' "$producer" "$status" >&2
      exit 1
    fi
    mapfile -t family <<<"$listed"
    for suite in "${family[@]}"; do
      if [[ -z "$suite" || ! -f "$suite" || -n "${discovered[$suite]:-}" ]]; then
        printf 'FAILED suite list: %s (empty, missing or repeated suite: %s)\n' "$producer" "$suite" >&2
        exit 1
      fi
      discovered[$suite]=1
      suites+=("$suite")
    done
  done
  set -- "${suites[@]}"
fi

out=$(mktemp -d)
trap 'rm -rf -- "$out"' EXIT
declare -A index_of=()
names=() started=() failed=()

reap() { # wait for one running suite, then print it whole and record its result
  local pid status=0 i
  wait -n -p pid "${!index_of[@]}" || status=$?
  [[ -n "${pid:-}" && -n "${index_of[${pid:-}]:-}" ]] || {
    printf 'could not identify completed suite (wait exit %d)\n' "$status" >&2; exit 1;
  }
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
  printf '[suite] START %s\n' "$suite"
  bash "$suite" >"$out/$i.log" 2>&1 </dev/null &
  index_of[$!]=$i
done
while ((${#index_of[@]})); do reap; done

if ((${#failed[@]})); then
  printf 'FAILED suites: %s\n' "${failed[*]}" >&2
  exit 1
fi
