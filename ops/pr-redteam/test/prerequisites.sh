#!/usr/bin/env bash
# The extracted collector reads the stand-in API globals.
# shellcheck disable=SC2034
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../pr-redteam"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
for f in prerequisite_evidence prerequisite_view upstream_capped; do
  eval "$(sed -n "/^$f() {/,/^}/p" "$script")"
done
# The supplemental views must hide exactly what diff.patch hides, so they share its pathspecs.
eval "$(sed -n '/^read_pathspecs=(/,/go.sum/p' "$script")"
[ "${#read_pathspecs[@]}" -ge 2 ]
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
echo head-lock >"$t/repo/Cargo.lock"
g add .; g commit -qm 'Release promotion (#36)'
head="$(g rev-parse HEAD)"
g checkout -q --detach "$prerequisite"
echo main-only >"$t/repo/main-only"
echo main-lock >"$t/repo/package-lock.json"
g add .; g commit -qm 'Other accepted work'
tip="$(g rev-parse HEAD)"
g update-ref refs/pr/36/base "$tip"
protected=true api_tip="$tip" api_code=200 api_shape=normal api_calls=0
api() {
  [ "$2" = /api/v1/repos/acme%2Ftool/refs ]
  api_calls=$((api_calls + 1))
  code="$api_code"
  body="$(jq -nc --arg sha "$api_tip" --argjson protected "$protected" \
    '[{name:"main", kind:"branch", sha:$sha, protected:$protected}]')"
  case "$api_shape" in
    missing_sha) body="$(jq 'map(del(.sha))' <<<"$body")" ;;
    missing_main) body='[]' ;;
    malformed) body='{}' ;;
  esac
}
g diff "$base...$head" -- "${read_pathspecs[@]}" >"$t/full.patch"
mkdir "$t/review"
cp "$t/full.patch" "$t/review/diff.patch"
prerequisite_evidence "$t/repo" acme/tool 36 "$base" "$head" "$t/review" 100000
out="$t/review/prerequisites"
grep -q "Accepted prerequisite boundary: $prerequisite" "$out/SUMMARY.txt"
grep -q "$prerequisite Accepted gate prerequisite (#35)" "$out/accepted-commits.txt"
grep -q 'not reviewer approval' "$out/SUMMARY.txt"
g diff "$tip...$head" -- "${read_pathspecs[@]}" >"$t/effective"
cmp "$t/effective" "$out/effective.patch"
grep -q '+remaining' "$out/effective.patch"
if grep -q '+prerequisite' "$out/effective.patch"; then exit 1; fi
grep -q '+main-only' "$out/main-only.patch"
grep -q 'Lock files are excluded' "$out/SUMMARY.txt"
# Lock files are excluded from the supplemental views exactly as from diff.patch.
for lock in head-lock main-lock; do
  if grep -q "+$lock" "$out/effective.patch" "$out/main-only.patch" "$t/review/diff.patch"; then exit 1; fi
done
cmp "$t/full.patch" "$t/review/diff.patch"
grep -q '+prerequisite' "$t/review/diff.patch"
for scenario in unprotected stale unavailable missing_sha missing_main malformed unchanged divergent missing_ref unrelated; do
  protected=true api_tip="$tip" api_code=200 retained="$base" api_shape=normal
  expected='' calls_before="$api_calls"
  g update-ref refs/pr/36/base "$tip"
  case "$scenario" in
    unprotected) protected=false; expected='main is not reported protected' ;;
    stale) api_tip="$base"; expected='main SHA is stale' ;;
    unavailable) api_code=503; expected='HTTP 503' ;;
    missing_sha) api_shape=missing_sha; expected='main SHA missing or invalid' ;;
    missing_main|malformed) api_shape="$scenario"; expected='missing main branch or malformed' ;;
    unchanged) retained="$tip" ;;
    divergent) retained="$head"; expected='does not descend' ;;
    missing_ref) g update-ref -d refs/pr/36/base; expected='fetched base ref missing' ;;
    unrelated)
      tree="$(g rev-parse "$base^{tree}")"
      unrelated="$(echo unrelated | g commit-tree "$tree")"
      g update-ref refs/pr/36/base "$unrelated"; expected='unrelated histories' ;;
  esac
  mkdir "$t/$scenario"
  prerequisite_evidence "$t/repo" acme/tool 36 "$retained" "$head" "$t/$scenario" 100000
  [[ ! -d "$t/$scenario/prerequisites" ]]
  if [[ -n "$expected" ]]; then
    grep -q "$expected" "$t/$scenario/prerequisite-status.txt"
  else
    [[ ! -e "$t/$scenario/prerequisite-status.txt" ]]
  fi
  case "$scenario" in unchanged|divergent|missing_ref|unrelated) [[ "$api_calls" == "$calls_before" ]] ;; esac
done
g update-ref refs/pr/36/base "$tip"
protected=true api_tip="$tip" api_code=200 api_shape=normal
mkdir "$t/capped"
prerequisite_evidence "$t/repo" acme/tool 36 "$base" "$head" "$t/capped" 10
grep -q 'effective.patch: 3 bytes; truncated=true; git_error=false' "$t/capped/prerequisites/SUMMARY.txt"
[[ "$(cat "$t/capped/prerequisites/"*.patch "$t/capped/prerequisites/accepted-commits.txt" | wc -c)" -le 10 ]]
# A Git failure is reported as an error, not as truncation, and spends nothing of the allowance.
mkdir "$t/giterr"
g update-ref refs/pr/36/base "$tip"
real_git="$(command -v git)"
mkdir "$t/shim"
printf '#!/bin/sh\ncase "$*" in *"diff %s...%s"*) exit 128 ;; esac\nexec "%s" "$@"\n' "$head" "$tip" "$real_git" >"$t/shim/git"
chmod +x "$t/shim/git"
PATH="$t/shim:$PATH" prerequisite_evidence "$t/repo" acme/tool 36 "$base" "$head" "$t/giterr" 100000
grep -q 'main-only.patch: git_error=true' "$t/giterr/prerequisites/SUMMARY.txt"
grep -q 'effective.patch: .*truncated=false; git_error=false' "$t/giterr/prerequisites/SUMMARY.txt"
[[ ! -s "$t/giterr/prerequisites/main-only.patch" ]]
if grep -q 'main-only.patch.*truncated' "$t/giterr/prerequisites/SUMMARY.txt"; then exit 1; fi
[[ "$prerequisite_spent" -gt 0 ]]
# The supplement is bounded by the allowance it is given, summed across views.
[[ "$(cat "$t/capped/prerequisites/"*.patch "$t/capped/prerequisites/accepted-commits.txt" | wc -c)" -le 10 ]]
echo 'ok stacked retained-base packet preserves complete diff, proves protected-main boundary, and discloses effective diff and limits'
