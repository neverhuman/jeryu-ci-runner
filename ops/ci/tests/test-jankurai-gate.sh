#!/usr/bin/env bash
# Offline tests of ops/ci/jankurai-gate.sh --report: the verdict it renders from
# a report the auditor already wrote. The no-changes report is the one the
# pinned Jankurai 1.7.5 really wrote for `diff-audit --base-ref HEAD` on a clean
# checkout, recorded as a fixture: a head equal to its base (main gating its own
# head, or a fresh main checkout) changes nothing, so it passes. Anything short
# of that exact shape or a full diff score still fails closed.
set -euo pipefail
cd "$(dirname "$0")/../../.."
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
no_changes=ops/ci/tests/fixtures/jankurai-1.7.5-diff-audit-no-changes.json

verdict() { JERYU_JANKURAI_GATE=1 bash ops/ci/jankurai-gate.sh --report "$1" 2>&1; }

out="$(verdict "$no_changes")" || fail "the real no-changes report failed the gate: $out"
[[ "$(head -1 <<<"$out")" == "no changes to score" ]] || fail "unexpected no-changes verdict: $out"
grep -q 'jankurai-gate: PASS' <<<"$out" || fail 'no-changes did not print PASS'

# Each mutation of the no-changes report is no longer that report, and has no
# verdict of its own: the gate refuses it.
refuse() {
  local name="$1" filter="$2"
  jq "$filter" "$no_changes" >"$fixture/$name.json"
  if out="$(verdict "$fixture/$name.json")"; then fail "the gate passed a $name report: $out"; fi
  grep -q 'jankurai audit produced no score' <<<"$out" || fail "$name did not fail closed: $out"
}
refuse changed '.changed_count = 3'
refuse hard '.hard_findings = 1'
refuse capped '.caps_applied = 1'
refuse low '.score = 90'
refuse string-count '.changed_count = "0"'
refuse other-result '.result = "scored"'
refuse host-error '.host_error = "the auditor exited 101"'
printf '{"result":"no-changes"}\n' >"$fixture/bare.json"
if verdict "$fixture/bare.json" >/dev/null; then fail 'the gate passed a bare no-changes result'; fi
printf 'not json\n' >"$fixture/garbage.json"
if verdict "$fixture/garbage.json" >/dev/null; then fail 'the gate passed a malformed report'; fi
printf 'ok - jankurai-gate passes the real no-changes report and refuses its mutations\n'
