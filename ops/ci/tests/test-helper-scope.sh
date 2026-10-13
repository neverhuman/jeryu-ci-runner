#!/usr/bin/env bash
# dependency-sources.sh hands the forge token only to a reviewed credential helper. The hosted gate
# (run under `env -i`) accepts exactly its own pinned helper; an operator host's reviewed helper is
# accepted only on a run that opts in with JERYU_CI_OPERATOR_HELPER=1. Runs the script's own
# helper_scope against invented hashes.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../dependency-sources.sh"
fail() { echo "not ok - $1" >&2; exit 1; }

fn="$(sed -n '/^helper_scope() {/,/^}/p' "$script")"
[ -n "$fn" ] || fail "helper_scope not found in dependency-sources.sh"
eval "$fn"
grep -q '\-z "$(helper_scope "$(sha256sum "${credential_helper}"' "$script" \
  || fail "the helper check does not go through helper_scope"
grep -q 'credential_helper_scope:\$credential_helper_scope' "$script" \
  || fail "the evidence does not record which scope accepted the helper"

gate="$(printf 'a%.0s' {1..64})" operator="$(printf 'b%.0s' {1..64})" other="$(printf 'c%.0s' {1..64})"
# shellcheck disable=SC2034 # read by the eval'd helper_scope
helper_binary_sha256_gate="$gate"
# shellcheck disable=SC2034
helper_binary_sha256_operator=("$operator")
scope() { helper_scope "$1" || true; }

unset JERYU_CI_OPERATOR_HELPER
[ "$(scope "$gate")" = gate ] || fail "the gate helper is accepted"
[ -z "$(scope "$operator")" ] || fail "without the opt-in an operator helper is refused (the hosted gate's set is one hash)"
[ -z "$(scope "$other")" ] || fail "an unlisted helper is refused"

export JERYU_CI_OPERATOR_HELPER=1
[ "$(scope "$operator")" = operator ] || fail "with the opt-in a reviewed operator helper is accepted"
[ "$(scope "$gate")" = gate ] || fail "with the opt-in the gate helper still reads as gate"
[ -z "$(scope "$other")" ] || fail "with the opt-in an unlisted helper is still refused"
for bad in "${operator:0:12}" "" "$operator $gate" "${operator^^}" " $operator" "x$operator"; do
  [ -z "$(scope "$bad")" ] || fail "a malformed hash is refused: '$bad'"
done
JERYU_CI_OPERATOR_HELPER=true
[ -z "$(scope "$operator")" ] || fail "only the exact opt-in value 1 counts"

IFS=$'\n'
JERYU_CI_OPERATOR_HELPER=1
[ "$(scope "$operator")" = operator ] && [ -z "$(scope "$other")" ] || fail "the check does not depend on IFS"
echo "ok - the hosted gate accepts only its helper; an operator helper only with JERYU_CI_OPERATOR_HELPER=1"
