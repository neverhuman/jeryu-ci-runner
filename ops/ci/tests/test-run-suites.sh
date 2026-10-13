#!/usr/bin/env bash
# Exercise the pool and its checked family discovery with independent fixture suites.
set -euo pipefail
run="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/run-suites.sh"
fx=$(mktemp -d)
pool=""
cleanup() {
  touch "$fx/release.a" "$fx/release.b" "$fx/release.c"
  if [[ -n "$pool" ]]; then wait "$pool" || true; fi
  rm -rf -- "$fx"
}
trap cleanup EXIT
must() { local why=$1; shift; "$@" || { printf 'FAIL: %s\n' "$why" >&2; exit 1; }; }
absent() { [[ ! -e "$1" ]]; }
await_start() {
  local n=$1 deadline=$((SECONDS + 30))
  until [[ -e "$fx/start.$n" ]]; do
    ((SECONDS < deadline)) || { printf 'FAIL: suite %s never started\n' "$n" >&2; exit 1; }
    sleep 0.02
  done
}
reset_barriers() { rm -f -- "$fx"/start.* "$fx"/release.*; }
finish_pool() {
  touch "$fx/release.a" "$fx/release.b" "$fx/release.c"
  wait "$pool"
  pool=""
}

# A suite stays running until explicitly released: overlap and ordering do not depend on speed.
for n in a b c; do
  cat >"$fx/$n.sh" <<SUITE
echo '$n one'
touch '$fx/start.$n'
while [[ ! -e '$fx/release.$n' ]]; do sleep 0.02; done
echo '$n two'
SUITE
done
printf 'echo "bad says why"; exit 3\n' >"$fx/bad.sh"

JERYU_CI_SUITE_JOBS=3 bash "$run" "$fx/a.sh" "$fx/b.sh" "$fx/c.sh" >"$fx/out" 2>&1 &
pool=$!
for n in a b c; do await_start "$n"; done
must 'running suites are named before buffered output' grep -q '^\[suite\] START ' "$fx/out"
finish_pool
out=$(cat "$fx/out")
must "each suite's output prints whole, never interleaved" \
  bash -c 'grep -v "^\[suite\]" <<<"$1" | awk "{ print \$1 }" | uniq | wc -l | grep -qx 3' _ "$out"
must 'each suite reports its time' test "$(grep -c '^\[suite\] .*/[abc]\.sh [0-9]*s$' <<<"$out")" -eq 3
printf 'PASS suites run side by side, each printed whole with its time\n'

reset_barriers
JERYU_CI_SUITE_JOBS=1 bash "$run" "$fx/a.sh" "$fx/b.sh" >"$fx/out" 2>&1 &
pool=$!
await_start a
must 'with one slot the blocked first suite keeps the second from starting' absent "$fx/start.b"
touch "$fx/release.a"
await_start b
finish_pool
reset_barriers
env -u JERYU_CI_SUITE_JOBS JERYU_CI_JOBS=40 bash "$run" "$fx/a.sh" "$fx/b.sh" "$fx/c.sh" >"$fx/out" 2>&1 &
pool=$!
await_start a; await_start b
must 'Cargo workers do not enlarge the default two-slot suite pool' absent "$fx/start.c"
touch "$fx/release.a"
await_start c
finish_pool
printf 'PASS dedicated bounded suite jobs, independently of Cargo workers; ordering uses barriers\n'

status=0
out=$(JERYU_CI_SUITE_JOBS=2 bash "$run" "$fx/bad.sh" "$fx/a.sh" "$fx/missing.sh" 2>&1) || status=$?
must 'a failed suite fails the run' test "$status" -eq 1
must 'its output is shown' grep -q '^bad says why$' <<<"$out"
must 'and it is marked failed with its exit' grep -q 'bad\.sh [0-9]*s FAILED (exit 3)$' <<<"$out"
must 'the others still run' grep -q '^a two$' <<<"$out"
must 'the failed and missing suites are named' grep -q "^FAILED suites: $fx/bad.sh $fx/missing.sh\$\|^FAILED suites: $fx/missing.sh $fx/bad.sh\$" <<<"$out"
for bad in 0 5 40 x; do
  must 'an invalid or excessive suite job count is refused' \
    bash -c '! JERYU_CI_SUITE_JOBS="$1" bash "$2" "$3" 2>/dev/null' _ "$bad" "$run" "$fx/a.sh"
done
printf 'PASS a failed or missing suite fails the run and is named; the rest still run\n'

# Both producers must succeed with complete, nonempty valid output before any family runs.
printf "echo first >>'%s/dispatched'\n" "$fx" >"$fx/first-suite.sh"
printf "echo second >>'%s/dispatched'\n" "$fx" >"$fx/second-suite.sh"
printf "printf '%%s\\n' '%s/first-suite.sh'\n" "$fx" >"$fx/first-list.sh"
printf "printf '%%s\\n' '%s/second-suite.sh'\n" "$fx" >"$fx/second-list.sh"
bash "$run" --list "$fx/first-list.sh" "$fx/second-list.sh" >"$fx/out" 2>&1
must 'both healthy family lists dispatch both suites' test "$(wc -l <"$fx/dispatched")" -eq 2
cp "$fx/second-list.sh" "$fx/healthy-second.sh"
for failure in empty refusal partial missing blank duplicate; do
  rm -f -- "$fx/dispatched"
  case "$failure" in
    empty) printf 'exit 0\n' >"$fx/second-list.sh" ;;
    refusal) printf 'exit 23\n' >"$fx/second-list.sh" ;;
    partial) cat "$fx/healthy-second.sh" >"$fx/second-list.sh"; printf 'exit 23\n' >>"$fx/second-list.sh" ;;
    missing) printf "printf '%%s\\n' '%s/absent-suite.sh'\n" "$fx" >"$fx/second-list.sh" ;;
    blank) printf "printf '%%s\\n\\n%%s\\n' '%s/second-suite.sh' '%s/second-suite.sh'\n" "$fx" "$fx" >"$fx/second-list.sh" ;;
    duplicate) cp "$fx/first-list.sh" "$fx/second-list.sh" ;;
  esac
  status=0
  out=$(bash "$run" --list "$fx/first-list.sh" "$fx/second-list.sh" 2>&1) || status=$?
  must "second family $failure fails the pool" test "$status" -eq 1
  must 'the refused producer is named' grep -Fq "FAILED suite list: $fx/second-list.sh" <<<"$out"
  must 'no first-family suite is dispatched before full discovery succeeds' absent "$fx/dispatched"
done
cp "$fx/healthy-second.sh" "$fx/second-list.sh"
printf 'exit 23\n' >"$fx/first-list.sh"
status=0
out=$(bash "$run" --list "$fx/first-list.sh" "$fx/second-list.sh" 2>&1) || status=$?
must 'a failed first family also refuses all dispatch' test "$status" -eq 1
must 'first family refusal leaves no executed suites' absent "$fx/dispatched"
printf 'PASS checked discovery refuses failed, partial, empty, invalid and duplicate families before dispatch\n'
