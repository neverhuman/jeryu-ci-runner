#!/usr/bin/env bash
# Offline, deterministic: a failed or malformed review must never become an approval.
# A fake `claude` (REDTEAM_CLAUDE) emits each case; `pr-redteam _agent` must reject every bad one and
# accept exactly the two valid ones. No network, no model, no real token.
#   test/verdict-validation.sh      exit 0 when every case behaves
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT

cat >"$t/fake-claude" <<'F'
#!/usr/bin/env bash
ok='{"verdict":"approve","summary":"fine","findings":[]}'
crit='{"severity":"critical","title":"t","file":"f","detail":"d","evidence":"e"}'
env() { printf '{"type":"result","subtype":"%s","is_error":%s,"structured_output":%s}\n' "$1" "$2" "$3"; }
case "$FAKE_CASE" in
  valid_approve)          env success false "$ok" ;;
  valid_block)            env success false "{\"verdict\":\"block\",\"summary\":\"bad\",\"findings\":[$crit]}" ;;
  approve_then_exit42)    env success false "$ok"; exit 42 ;;
  approve_then_timeout)   env success false "$ok"; sleep 30 ;;
  invalid_verdict_enum)   env success false '{"verdict":"reject","summary":"x","findings":[]}' ;;
  approve_with_critical)  env success false "{\"verdict\":\"approve\",\"summary\":\"x\",\"findings\":[$crit]}" ;;
  block_without_critical) env success false '{"verdict":"block","summary":"x","findings":[]}' ;;
  envelope_is_error)      env error_during_execution true "$ok" ;;
  missing_summary)        env success false '{"verdict":"approve","findings":[]}' ;;
  bad_severity)           env success false '{"verdict":"approve","summary":"x","findings":[{"severity":"urgent","title":"t","file":"f","detail":"d","evidence":"e"}]}' ;;
  no_output)              exit 0 ;;
esac
F
chmod +x "$t/fake-claude"

mkdir -p "$t/review" "$t/state"
: >"$t/review/diff.patch"; : >"$t/review/files.txt"; : >"$t/review/numstat.txt"
echo dummy >"$t/token"

run() { # case -> stdout of _agent, exit status preserved
  FAKE_CASE="$1" REDTEAM_CLAUDE="$t/fake-claude" REDTEAM_TIMEOUT=3 REDTEAM_STATE="$t/state" \
    JERYU_TOKEN_FILE="$t/token" "$here/pr-redteam" _agent "$t/review" "x/y#1" 0000000000000000000000000000000000000000 2>/dev/null
}

fail=0
for c in approve_then_exit42 approve_then_timeout invalid_verdict_enum approve_with_critical \
         block_without_critical envelope_is_error missing_summary bad_severity no_output; do
  if out="$(run "$c")"; then echo "FAIL $c: accepted -> $out"; fail=1; else echo "ok   $c: rejected"; fi
done
for c in valid_approve valid_block; do
  if out="$(run "$c")" && [ -n "$out" ]; then echo "ok   $c: accepted"; else echo "FAIL $c: rejected"; fail=1; fi
done
[ "$fail" = 0 ] && echo "VERDICT VALIDATION PASS" || { echo "VERDICT VALIDATION FAIL"; exit 1; }
