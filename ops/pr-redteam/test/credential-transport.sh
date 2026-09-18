#!/usr/bin/env bash
# Whole-command transport checks. Only the fixture bearer and fake curl are used.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
cat > "$t/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$TRANSPORT_FIXTURE/argv"
cat > "$TRANSPORT_FIXTURE/stdin"
[[ "$1" == --disable ]]
! grep -q 'fixture-bearer' "$TRANSPORT_FIXTURE/argv"
grep -q '^header = "Authorization: Bearer fixture-bearer"$' "$TRANSPORT_FIXTURE/stdin"
grep -q '^--proto$' "$TRANSPORT_FIXTURE/argv"
grep -q '^=https$' "$TRANSPORT_FIXTURE/argv"
grep -q '^https://git.neverhuman.org/api/v1/runners/heartbeat$' "$TRANSPORT_FIXTURE/argv"
printf '{"accepted":true}\n200'
FIXTURE
chmod +x "$t/bin/curl"
run() {
  TRANSPORT_FIXTURE="$t" PATH="$t/bin:$PATH" JERYU_BASE="$1" JERYU_TOKEN_FILE="$2" \
    REDTEAM_STATE="$t/state" "$here/pr-redteam" heartbeat > "$t/out" 2>&1
}
check() {
  local name="$1" expected="$2" base="$3" token="$4" rc=0
  rm -f "$t/argv" "$t/stdin"
  run "$base" "$token" || rc=$?
  if [[ "$expected" == pass ]]; then
    [[ "$rc" == 0 && -s "$t/stdin" ]]
    ! grep -q fixture-bearer "$t/out"
  else [[ "$rc" != 0 && ! -e "$t/argv" ]]; fi
  printf 'ok %s\n' "$name"
}
printf 'fixture-bearer\n' > "$t/token"
check canonical pass https://git.neverhuman.org "$t/token"
check wrong-origin reject https://example.invalid "$t/token"
check cleartext reject http://git.neverhuman.org "$t/token"
check path-prefix reject https://git.neverhuman.org/prefix "$t/token"
chmod 644 "$t/token"
check token-permission reject https://git.neverhuman.org "$t/token"
chmod 600 "$t/token"
printf 'fixture-bearer\nInjected: header\n' > "$t/token"
check header-newline reject https://git.neverhuman.org "$t/token"
printf 'fixture-bearer\n' > "$t/token"
ln -s "$t/token" "$t/link"
check token-symlink reject https://git.neverhuman.org "$t/link"
echo 'CREDENTIAL TRANSPORT PASS'
