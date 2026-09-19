#!/usr/bin/env bash
# Every heartbeat the forge does not accept must leave a "heartbeat refused" log line, whatever
# shape the refusal takes. Only the fixture bearer and fake curl are used.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
cat > "$t/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
cat > /dev/null
case "$HEARTBEAT_FIXTURE" in
  accepted) printf '{"accepted":true,"runnerId":"xbabe0/redteam"}\n200' ;;
  json-403) printf '{"code":"permission_denied","message":"this account may not report runner heartbeats (JERYU_RUNNER_REPORTERS)"}\n403' ;;
  html-403) printf '<html>\n<body>403 Forbidden</body>\n</html>\n403' ;;
  empty-502) printf '\n502' ;;
  unreachable) echo 'curl: (7) Failed to connect' >&2; exit 7 ;;
esac
FIXTURE
chmod +x "$t/bin/curl"
printf 'fixture-bearer\n' > "$t/token"
check() {
  local fixture="$1" expected="$2"
  HEARTBEAT_FIXTURE="$fixture" PATH="$t/bin:$PATH" JERYU_TOKEN_FILE="$t/token" \
    REDTEAM_STATE="$t/state" "$here/pr-redteam" heartbeat > "$t/out" 2>&1
  if [[ -z "$expected" ]]; then
    [[ ! -s "$t/out" ]] || { echo "unexpected log for $fixture: $(cat "$t/out")" >&2; exit 1; }
  else
    grep -qF -- "$expected" "$t/out" || { echo "missing log for $fixture: $(cat "$t/out")" >&2; exit 1; }
  fi
  printf 'ok %s\n' "$fixture"
}
check accepted ''
check json-403 'heartbeat refused (403): "this account may not report runner heartbeats (JERYU_RUNNER_REPORTERS)"'
check html-403 'heartbeat refused (403): non-JSON answer: <html> <body>403 Forbidden</body> </html>'
check empty-502 'heartbeat refused (502): non-JSON answer:'
check unreachable 'heartbeat refused (no answer): curl failed'
echo 'HEARTBEAT LOG PASS'
