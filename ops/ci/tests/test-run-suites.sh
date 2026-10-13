#!/usr/bin/env bash
# Exercise ops/ci/run-suites.sh: suites run side by side up to the job cap, each one's output
# prints whole, and any failed or missing suite fails the run and is named.
set -euo pipefail
run="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/run-suites.sh"
fx=$(mktemp -d)
trap 'rm -rf -- "$fx"' EXIT
must() { local why=$1; shift; "$@" || { printf 'FAIL: %s\n' "$why" >&2; exit 1; }; }

# Each suite records when it ran, prints two lines with a pause between, and passes or fails.
for n in a b c; do
  printf 'printf "%%s start %%s\\n" %s "$(date +%%s%%N)" >>"%s/runs"\necho "%s one"; sleep 1; echo "%s two"\n' \
    "$n" "$fx" "$n" "$n" >"$fx/$n.sh"
done
printf 'echo "bad says why"; exit 3\n' >"$fx/bad.sh"

out=$(JERYU_CI_JOBS=3 bash "$run" "$fx/a.sh" "$fx/b.sh" "$fx/c.sh")
must 'all three ran' test "$(wc -l <"$fx/runs")" -eq 3
starts=$(awk '{ print $3 }' "$fx/runs" | sort -n)
must 'with three slots, all three start within half a second' \
  test $(( ($(tail -1 <<<"$starts") - $(head -1 <<<"$starts")) / 1000000 )) -lt 500
must "each suite's output prints whole, never interleaved" \
  bash -c 'grep -v "^\[suite\]" <<<"$1" | awk "{ print \$1 }" | uniq | wc -l | grep -qx 3' _ "$out"
must 'each suite reports its time' test "$(grep -c '^\[suite\] .*/[abc]\.sh [0-9]*s$' <<<"$out")" -eq 3
printf 'PASS suites run side by side, each printed whole with its time\n'

: >"$fx/runs"
JERYU_CI_JOBS=1 bash "$run" "$fx/a.sh" "$fx/b.sh" >/dev/null
starts=$(awk '{ print $3 }' "$fx/runs" | sort -n)
must 'with one slot, the second starts only after the first ends' \
  test $(( ($(tail -1 <<<"$starts") - $(head -1 <<<"$starts")) / 1000000 )) -ge 900
printf 'PASS JERYU_CI_JOBS caps how many run at once\n'

status=0
out=$(JERYU_CI_JOBS=2 bash "$run" "$fx/bad.sh" "$fx/a.sh" "$fx/missing.sh" 2>&1) || status=$?
must 'a failed suite fails the run' test "$status" -eq 1
must 'its output is shown' grep -q '^bad says why$' <<<"$out"
must 'and it is marked failed with its exit' grep -q 'bad\.sh [0-9]*s FAILED (exit 3)$' <<<"$out"
must 'the others still run' grep -q '^a two$' <<<"$out"
must 'the failed and missing suites are named' grep -q "^FAILED suites: $fx/bad.sh $fx/missing.sh\$\|^FAILED suites: $fx/missing.sh $fx/bad.sh\$" <<<"$out"
must 'a bad job count is refused' bash -c '! JERYU_CI_JOBS=0 bash "$1" "$2" 2>/dev/null' _ "$run" "$fx/a.sh"
printf 'PASS a failed or missing suite fails the run and is named; the rest still run\n'
