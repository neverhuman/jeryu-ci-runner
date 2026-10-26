#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
source ops/ci/proof_guards.sh
fixture="$(mktemp -d)"
trap 'rm -r -- "$fixture"' EXIT
# Execute the history guard with a depth-1 Git model. Fetch failures must
# propagate, and refreshing main must happen only after deepening succeeds.
git() {
  printf '%s\n' "$*" >> "$fixture/calls"
  case "$*" in
    'rev-parse --is-shallow-repository') echo true ;;
    'fetch --quiet --no-tags --unshallow origin main') return "$fetch_status" ;;
    'fetch --quiet --no-tags origin +refs/heads/main:refs/remotes/origin/main') return 0 ;;
    *) return 1 ;;
  esac
}
fetch_status=0
proof_require_history
[[ "$(sed -n '2p' "$fixture/calls")" == 'fetch --quiet --no-tags --unshallow origin main' ]]
[[ "$(sed -n '3p' "$fixture/calls")" == 'fetch --quiet --no-tags origin +refs/heads/main:refs/remotes/origin/main' ]]
fetch_status=1
if proof_require_history; then echo 'accepted a failed history fetch' >&2; exit 1; fi
unset -f git
printf '%s\n' '{"schema_version":"1.0.0","status":"complete","liability_score":4,"required_proof_lanes":[],"rollback_cutover_notes":["restore"]}' > "$fixture/base"
cp "$fixture/base" "$fixture/head"
proof_require_migration "$fixture/base" "$fixture/head"
for filter in '.liability_score=5' '.status="partial"' 'del(.liability_score)' '.liability_score=-1' '.rollback_cutover_notes=[]'; do
  jq "$filter" "$fixture/base" > "$fixture/head"
  if proof_require_migration "$fixture/base" "$fixture/head"; then
    printf 'accepted migration regression: %s\n' "$filter" >&2; exit 1
  fi
done
jq '.status="partial"' "$fixture/base" > "$fixture/bad-base"
if proof_require_migration "$fixture/bad-base" "$fixture/base"; then
  echo 'accepted incomplete baseline analysis' >&2; exit 1
fi
grep -qx 'bash ops/ci/proof_evidence.sh' ops/ci/pr-ci.sh
printf 'proof guards ok\n'

# The lane's wiring: what one file cannot show a reader -- where its ratchet
# baseline comes from, that no tool result is discarded or stood in for, and
# that the required gate and the lane catalog both run it.
lane=ops/ci/proof_evidence.sh
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

grep -n '|| true' "$lane" | grep -qv 'cleanup_baseline || true' &&
  fail 'a tool in the lane has its failure discarded' || :
grep -q 'git clone --quiet --no-local' "$lane" ||
  fail 'the ratchet baseline does not come from a clone of protected main'
grep -q 'agent/baselines' "$lane" &&
  fail 'the ratchet baseline may not come from a file in the tree under test' || :
grep -q 'candidate audit policy must be byte-identical to protected main' "$lane" ||
  fail 'the lane does not check that main policy judges this head'
# Every write into target/ is a tool's own output or this run's summary; a
# `printf > target/...` fallback would be a result nobody produced.
while IFS= read -r line; do
  [[ "$line" == '  > target/jankurai/proof-evidence-summary.json' ]] ||
    fail "the lane synthesizes an artifact: $line"
done < <(grep -E '> *target/' "$lane" | grep -v '^[[:space:]]*#')

# Order: the history guard runs before ancestry is asked, the stale artifacts of
# an earlier run go before the first tool, and the migration gate reads both
# analyses after they are produced.
line_of() {
  local n
  n="$(grep -n -m1 -e "$1" "$lane" | cut -d: -f1)"
  [[ -n "$n" ]] || fail "the lane does not contain: $1"
  printf '%s\n' "$n"
}
(( $(line_of '^proof_require_history$') < $(line_of 'merge-base --is-ancestor') )) ||
  fail 'ancestry is asked before the checkout has its history'
(( $(line_of '^rm -rf -- \\$') < $(line_of '^jankurai proof \.') )) ||
  fail 'the lane runs a tool before clearing an earlier run artifacts'
(( $(line_of '^jankurai migrate \.') < $(line_of '^proof_require_migration') )) ||
  fail 'the migration gate reads a report the lane did not just produce'

grep -q '^name = "proof-evidence"$' agent/proof-lanes.toml ||
  fail 'the lane is not in the repository lane catalog'
grep -q '^command = "bash ops/ci/proof_evidence.sh"$' agent/proof-lanes.toml ||
  fail 'the catalog does not name the command the gate runs'
printf 'proof lane wiring ok\n'
