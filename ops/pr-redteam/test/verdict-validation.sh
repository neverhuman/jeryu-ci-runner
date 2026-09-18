#!/usr/bin/env bash
# Exercise the actual process/envelope/schema boundary with an offline CLI fixture.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
cat >"$t/fake-claude" <<'FIXTURE'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo "${FAKE_VERSION:-9.9.9} (Claude Code)"; exit 0; fi
ok='{"verdict":"approve","summary":"fine","findings":[]}'
crit='{"severity":"critical","title":"t","file":"f","detail":"d","evidence":"e"}'
emit() { printf '{"type":"result","subtype":"success","is_error":false,"structured_output":%s}\n' "$1"; }
case "$FAKE_CASE" in
  valid_approve) emit "$ok" ;;
  valid_block) emit "{\"verdict\":\"block\",\"summary\":\"bad\",\"findings\":[$crit]}" ;;
  valid_high_block) emit "{\"verdict\":\"block\",\"summary\":\"bad\",\"findings\":[${crit/critical/high}]}" ;;
  explicit_hold) emit '{"verdict":"block","summary":"review incomplete","findings":[]}' ;;
  approve_then_exit42) emit "$ok"; exit 42 ;;
  approve_then_timeout) emit "$ok"; sleep 30 ;;
  invalid_verdict_enum) emit '{"verdict":"reject","summary":"x","findings":[]}' ;;
  approve_with_critical) emit "{\"verdict\":\"approve\",\"summary\":\"x\",\"findings\":[$crit]}" ;;
  approve_with_high) emit "{\"verdict\":\"approve\",\"summary\":\"x\",\"findings\":[${crit/critical/high}]}" ;;
  envelope_is_error) emit "$ok" | jq '.is_error=true' ;;
  missing_error_flag) emit "$ok" | jq 'del(.is_error)' ;;
  wrong_envelope_type) emit "$ok" | jq '.type="message"' ;;
  multiple_envelopes) emit "$ok"; emit "$ok" ;;
  missing_summary) emit '{"verdict":"approve","findings":[]}' ;;
  empty_summary) emit '{"verdict":"approve","summary":"","findings":[]}' ;;
  extra_property) emit "$ok" | jq '.structured_output.extra=true' ;;
  bad_severity) emit "{\"verdict\":\"block\",\"summary\":\"x\",\"findings\":[${crit/critical/urgent}]}" ;;
  null_line|fractional_line|zero_line|extra_finding_property|missing_evidence|empty_evidence)
    v="{\"verdict\":\"block\",\"summary\":\"x\",\"findings\":[$crit]}"
    case "$FAKE_CASE" in
      null_line) filter='.structured_output.findings[0].line=null' ;;
      fractional_line) filter='.structured_output.findings[0].line=1.5' ;;
      zero_line) filter='.structured_output.findings[0].line=0' ;;
      extra_finding_property) filter='.structured_output.findings[0].extra=true' ;;
      missing_evidence) filter='del(.structured_output.findings[0].evidence)' ;;
      empty_evidence) filter='.structured_output.findings[0].evidence=""' ;;
    esac
    emit "$v" | jq "$filter" ;;
  no_output) exit 0 ;;
esac
FIXTURE
chmod +x "$t/fake-claude"
mkdir -p "$t/review" "$t/state"
: >"$t/review/diff.patch"; : >"$t/review/files.txt"; : >"$t/review/numstat.txt"
printf 'dummy\n' >"$t/token"
run() {
  FAKE_CASE="$1" FAKE_VERSION="${FAKE_VERSION:-9.9.9}" REDTEAM_CLAUDE_VERSION=9.9.9 \
    REDTEAM_CLAUDE="$t/fake-claude" REDTEAM_TIMEOUT=1 REDTEAM_STATE="$t/state" \
    JERYU_TOKEN_FILE="$t/token" "$here/pr-redteam" _agent "$t/review" "x/y#1" 0000000000000000000000000000000000000000 2>/dev/null
}
fail=0
for c in approve_then_exit42 approve_then_timeout invalid_verdict_enum approve_with_critical \
         approve_with_high envelope_is_error missing_error_flag wrong_envelope_type multiple_envelopes \
         missing_summary empty_summary extra_property bad_severity null_line fractional_line zero_line \
         extra_finding_property missing_evidence empty_evidence no_output; do
  if out="$(run "$c")"; then echo "FAIL $c: accepted -> $out"; fail=1; else echo "ok $c: rejected"; fi
done
if out="$(FAKE_VERSION=0.0.1 run valid_approve)"; then
  echo "FAIL cli_version_mismatch: accepted -> $out"; fail=1
else echo "ok cli_version_mismatch: rejected"; fi
for c in valid_approve valid_block valid_high_block explicit_hold; do
  if out="$(run "$c")" && [[ -n "$out" ]]; then echo "ok $c: accepted"; else echo "FAIL $c: rejected"; fail=1; fi
done
((fail == 0))
echo 'VERDICT VALIDATION PASS'
