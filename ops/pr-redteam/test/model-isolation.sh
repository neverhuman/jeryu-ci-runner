#!/usr/bin/env bash
# Verify the real launcher policy and refuse model output containing a fixture
# credential, even if a compromised model client manages to return it.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/review" "$t/state"
: > "$t/review/signals.txt"
printf 'sentinel-reviewer-bearer-123456789\n' > "$t/token"
cat > "$t/model" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
fixture_root="$(dirname "$0")"
if [[ "${1:-}" == --version ]]; then echo '9.9.9 (Claude Code)'; exit 0; fi
compgen -e > "$fixture_root/env-names"
compgen -A function > "$fixture_root/function-names" || true
printf '%s\n' "$@" > "$fixture_root/args"
secret="$(cat "$fixture_root/token")"
case "$(cat "$fixture_root/case")" in
  clean) value='review complete' ;;
  raw) value="$secret" ;;
  base64) value="$(printf '%s' "$secret" | base64 -w0)" ;;
  hex) value="$(printf '%s' "$secret" | od -An -tx1 | tr -d ' \n')" ;;
  spaced) value="$(printf '%s' "$secret" | sed 's/./& /g')" ;;
esac
jq -nc --arg summary "$value" '{type:"result",subtype:"success",is_error:false,structured_output:{verdict:"approve",summary:$summary,findings:[]}}'
FIXTURE
chmod +x "$t/model"
run() {
  printf '%s\n' "$1" > "$t/case"
  JERYU_BASE="${JERYU_BASE:-https://forge.invalid}" JERYU_TOKEN_FILE="$t/token" REDTEAM_MERGE_TOKEN_FILE="$t/merger-token" ARBITRARY_SERVICE_SECRET=fixture-only \
    REDTEAM_STATE="$t/state" REDTEAM_CLAUDE="$t/model" REDTEAM_CLAUDE_VERSION=9.9.9 \
    "$here/pr-redteam" _agent "$t/review" 'x/y#1' 0000000000000000000000000000000000000000 > "$t/output" 2> "$t/errors"
}
fail=0
injected_fixture_function() { :; }
export -f injected_fixture_function
run clean
if grep -Fxq injected_fixture_function "$t/function-names"; then echo 'FAIL model inherited an exported function'; fail=1; fi
if grep -Eq '^(JERYU_TOKEN_FILE|REDTEAM_MERGE_TOKEN_FILE|ARBITRARY_SERVICE_SECRET)$' "$t/env-names"; then
  echo 'FAIL model inherited controller authority'; fail=1
else echo 'ok model environment scrubbed'; fi
for flag in --restricted --safe-mode --tools --strict-mcp-config --mcp-config --no-session-persistence; do
  if ! grep -Fxq -- "$flag" "$t/args"; then echo "FAIL missing model policy flag $flag"; fail=1; fi
done
if grep -Fxq -- --setting-sources "$t/args"; then echo 'FAIL model loads ambient settings'; fail=1; fi
for case_name in raw base64 hex spaced; do
  if run "$case_name"; then echo "FAIL credential output accepted: $case_name"; fail=1
  else echo "ok credential output refused: $case_name"; fi
  if grep -Fq -f "$t/token" "$t/output" "$t/errors"; then echo 'FAIL credential reached controller output'; fail=1; fi
done
[[ "$fail" == 0 ]]
echo 'MODEL BOUNDARY PASS'
