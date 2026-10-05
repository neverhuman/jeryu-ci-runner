#!/usr/bin/env bash
# Every heartbeat the forge does not accept must leave a "heartbeat refused" log line, whatever
# shape the refusal takes, and every reviewer slot beats as its own runner row. Only the fixture
# bearer and fake curl are used.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
cat > "$t/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$@" >> "$HEARTBEAT_SENT"
case "$HEARTBEAT_FIXTURE" in
  accepted) printf '{"accepted":true,"runnerId":"fixture/redteam"}\n200' ;;
  json-403) printf '{"code":"permission_denied","message":"this account may not report runner heartbeats (JERYU_RUNNER_REPORTERS)"}\n403' ;;
  html-403) printf '<html>\n<body>403 Forbidden</body>\n</html>\n403' ;;
  empty-502) printf '\n502' ;;
  unreachable) echo 'curl: (7) Failed to connect' >&2; exit 7 ;;
esac
FIXTURE
chmod +x "$t/bin/curl"
printf 'fixture-bearer\n' > "$t/token"
beat() { # fixture jobs
  : > "$t/sent"
  HEARTBEAT_FIXTURE="$1" HEARTBEAT_SENT="$t/sent" PATH="$t/bin:$PATH" JERYU_TOKEN_FILE="$t/token" \
    REDTEAM_STATE="$t/state" REDTEAM_RUNNER_ID=fixture/redteam REDTEAM_JOBS="$2" \
    "$here/pr-redteam" heartbeat > "$t/out" 2>&1
}
check() {
  local fixture="$1" expected="$2"
  beat "$fixture" 1
  if [[ -z "$expected" ]]; then
    [[ ! -s "$t/out" ]] || { echo "unexpected log for $fixture: $(cat "$t/out")" >&2; exit 1; }
  else
    grep -qF -- "$expected" "$t/out" || { echo "missing log for $fixture: $(cat "$t/out")" >&2; exit 1; }
  fi
  printf 'ok %s\n' "$fixture"
}
check accepted ''
check json-403 'heartbeat refused for fixture/redteam (403): "this account may not report runner heartbeats (JERYU_RUNNER_REPORTERS)"'
check html-403 'heartbeat refused for fixture/redteam (403): non-JSON answer: <html> <body>403 Forbidden</body> </html>'
check empty-502 'heartbeat refused for fixture/redteam (502): non-JSON answer:'
check unreachable 'heartbeat refused for fixture/redteam (no answer): curl failed'

# Slots: three reviewers are three rows, and the review holding slot 1 is that row's `current`.
mkdir -p "$t/state/beats/slots" "$t/state/beats/current"
printf 'jeryu_jeryu-web-7\n' > "$t/state/beats/slots/1"
printf '{"repo":"jeryu/jeryu-web","pr":7,"sha":"abc","recipe":"redteam-review","started_at":"x","slot":1}\n' \
  > "$t/state/beats/current/jeryu_jeryu-web-7.json"
beat accepted 3
ids="$(grep -o '"runnerId":"[^"]*"' "$t/sent" | tr '\n' ' ')"
[[ "$ids" == '"runnerId":"fixture/redteam" "runnerId":"fixture/redteam-2" "runnerId":"fixture/redteam-3" ' ]] \
  || { echo "slot rows wrong: $ids" >&2; exit 1; }
[[ "$(grep -c '"current":{"repo":"jeryu/jeryu-web"' "$t/sent")" == 1 ]] \
  || { echo "the held slot did not report its review exactly once: $(cat "$t/sent")" >&2; exit 1; }
grep -q '"runnerId":"fixture/redteam-2","host":"[^"]*","slot":1,"labels":\["redteam"\],"current":{' "$t/sent" \
  || { echo "slot 1 is not the row reporting the review: $(cat "$t/sent")" >&2; exit 1; }
echo 'ok slots'
echo 'HEARTBEAT LOG PASS'
