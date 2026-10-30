#!/usr/bin/env bash
# The extracted collector reads the stand-in API globals.
# shellcheck disable=SC2034
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../pr-redteam"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
for f in prerequisite_evidence upstream_capped; do
  eval "$(sed -n "/^$f() {/,/^}/p" "$script")"
done
git init -q "$t/repo"
g() { git -C "$t/repo" "$@"; }
g config user.name Fixture
g config user.email fixture@example.test
echo initial >"$t/repo/code"
g add .; g commit -qm initial
base="$(g rev-parse HEAD)"
echo prerequisite >>"$t/repo/code"
g commit -qam 'Accepted gate prerequisite (#35)'
prerequisite="$(g rev-parse HEAD)"
echo remaining >"$t/repo/remaining"
g add .; g commit -qm 'Release promotion (#36)'
head="$(g rev-parse HEAD)"
g checkout -q --detach "$prerequisite"
echo main-only >"$t/repo/main-only"
g add .; g commit -qm 'Other accepted work'
tip="$(g rev-parse HEAD)"
g update-ref refs/pr/36/base "$tip"
protected=true api_tip="$tip" api_code=200
api() {
  [ "$2" = /api/v1/repos/acme%2Ftool/refs ]
  code="$api_code"
  body="$(jq -nc --arg sha "$api_tip" --argjson protected "$protected" \
    '[{name:"main", kind:"branch", sha:$sha, protected:$protected}]')"
}
g diff "$base...$head" >"$t/full.patch"
mkdir "$t/review"
cp "$t/full.patch" "$t/review/diff.patch"
prerequisite_evidence "$t/repo" acme/tool 36 "$base" "$head" "$t/review" 100000
out="$t/review/prerequisites"
grep -q "Accepted prerequisite boundary: $prerequisite" "$out/SUMMARY.txt"
grep -q "$prerequisite Accepted gate prerequisite (#35)" "$out/accepted-commits.txt"
grep -q 'not reviewer approval' "$out/SUMMARY.txt"
g diff "$tip...$head" >"$t/effective"
cmp "$t/effective" "$out/effective.patch"
grep -q '+remaining' "$out/effective.patch"
if grep -q '+prerequisite' "$out/effective.patch"; then exit 1; fi
grep -q '+main-only' "$out/main-only.patch"
cmp "$t/full.patch" "$t/review/diff.patch"
grep -q '+prerequisite' "$t/review/diff.patch"
for scenario in unprotected stale unavailable unchanged divergent; do
  protected=true api_tip="$tip" api_code=200 retained="$base"
  case "$scenario" in
    unprotected) protected=false ;;
    stale) api_tip="$base" ;;
    unavailable) api_code=503 ;;
    unchanged) retained="$tip" ;;
    divergent) retained="$head" ;;
  esac
  prerequisite_evidence "$t/repo" acme/tool 36 "$retained" "$head" "$t/$scenario" 100000
  grep -q 'No accepted prerequisite boundary established' "$t/$scenario/prerequisites/SUMMARY.txt"
done
prerequisite_evidence "$t/repo" acme/tool 36 "$base" "$head" "$t/capped" 10
grep -q 'effective.patch: 10 bytes; truncated=true' "$t/capped/prerequisites/SUMMARY.txt"
echo 'ok stacked retained-base packet preserves complete diff, proves protected-main boundary, and discloses effective diff and limits'
