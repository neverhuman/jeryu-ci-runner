#!/usr/bin/env bash
# The review identity covers the review inputs and not the script's plumbing: editing a part of
# pr-redteam that the agent never sees keeps it, while bumping review_format or editing prompt.md
# changes it. A receipt counts as "already reviewed" only under the current identity or one listed
# in REDTEAM_ACCEPT_IDENTITIES; malformed entries are ignored. Only a fake curl and the fixture
# bearer are used; `list` posts nothing.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/state/receipts/acme/widget-shop"
printf 'fixture-bearer\n' > "$t/token"
printf 'fixture claude bytes\n' > "$t/claude"
head=dddddddddddddddddddddddddddddddddddddddd
base=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
cat > "$t/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
method=GET
while (($#)); do
  case "$1" in
    --config) [[ "$2" != - ]] || cat > /dev/null; shift ;;
    -X) method="$2"; shift ;;
    --data) shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
[[ "$method" == GET ]] || { echo "unexpected write $method $url" >> "$IDENTITY_FIXTURE/danger"; exit 97; }
case "$url" in
  */api/v3/user) printf '{"login":"independent-reviewer"}\n200' ;;
  */api/v1/repos) printf '{"repositories":[{"id":{"owner":"acme","name":"widget-shop"},"family":"widgets","open_pull_requests":1}]}\n200' ;;
  *'/pulls?state=open')
    printf '{"items":[{"repo":{"owner":"acme","name":"widget-shop"},"number":7,"head_sha":"dddddddddddddddddddddddddddddddddddddddd","base_sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","head_ref":"cart-totals","base_ref":"main","draft":false,"author":"dana","title":"cart totals","state":"open","labels":["origin:internal"]}]}\n200' ;;
  *) printf '{"message":"unexpected %s %s"}\n404' "$method" "$url" ;;
esac
FIXTURE
chmod +x "$t/bin/curl"

# A private copy of the controller, so its files can be edited without touching the source tree.
copy() { # dir
  mkdir -p "$1"
  cp -p "$here/pr-redteam" "$here/prompt.md" "$here/verdict.schema.json" "$here/validate-verdict.jq" \
    "$here/claude-cli.version" "$1/"
}
run() { # dir command…
  local dir="$1"; shift
  IDENTITY_FIXTURE="$t" PATH="$t/bin:$PATH" JERYU_BASE=https://forge.invalid JERYU_TOKEN_FILE="$t/token" \
    REDTEAM_STATE="$t/state" REDTEAM_FAMILIES=all REDTEAM_CLAUDE="$t/claude" REDTEAM_MODEL=fixture-model \
    "$dir/pr-redteam" "$@"
}
fail() { echo "$*" >&2; exit 1; }

copy "$t/a"
original="$(run "$t/a" identity)"
[[ "$original" =~ ^[0-9a-f]{64}$ ]] || fail "identity is not 64 hex: $original"

# Plumbing: a change the agent never sees keeps the identity.
printf '\n# a heartbeat-only change\nheartbeat_note=1\n' >> "$t/a/pr-redteam"
[[ "$(run "$t/a" identity)" == "$original" ]] || fail 'a plumbing-only script change moved the review identity'
echo 'ok plumbing change keeps the review identity'

# review_format is part of the identity.
copy "$t/b"
grep -qx 'review_format=1' "$t/b/pr-redteam" || fail 'review_format=1 not found in pr-redteam'
sed -i 's/^review_format=1$/review_format=2/' "$t/b/pr-redteam"
bumped="$(run "$t/b" identity)"
[[ "$bumped" =~ ^[0-9a-f]{64}$ && "$bumped" != "$original" ]] || fail 'bumping review_format kept the review identity'
echo 'ok review_format bump changes the review identity'

# So is the prompt.
copy "$t/c"
printf '\nOne more instruction.\n' >> "$t/c/prompt.md"
prompted="$(run "$t/c" identity)"
[[ "$prompted" =~ ^[0-9a-f]{64}$ && "$prompted" != "$original" && "$prompted" != "$bumped" ]] \
  || fail 'editing prompt.md kept the review identity'
echo 'ok prompt change changes the review identity'

# A posted receipt from an earlier identity is not reused by default…
receipt="$t/state/receipts/acme/widget-shop/7-$head.json"
jq -n --arg sha "$head" --arg base "$base" --arg identity "$original" \
  '{repo:"acme/widget-shop",number:7,head_sha:$sha,base_sha:$base,decision:"approve",posted:true,review_identity:$identity}' \
  > "$receipt"
run "$t/a" list > "$t/out" 2>&1
grep -qF 'skip acme/widget-shop#7 — already reviewed' "$t/out" || { cat "$t/out" >&2; fail 'current identity receipt was not reused'; }
run "$t/b" list > "$t/out" 2>&1
grep -qF 'queue [family widgets] acme/widget-shop#7' "$t/out" || { cat "$t/out" >&2; fail 'a receipt from another identity was reused'; }
echo 'ok receipt from another identity requalifies'

# …until the operator lists it. Malformed entries are logged and ignored.
REDTEAM_ACCEPT_IDENTITIES="not-an-identity ${original^^} $original" run "$t/b" list > "$t/out" 2>&1
grep -qF 'skip acme/widget-shop#7 — already reviewed' "$t/out" || { cat "$t/out" >&2; fail 'an accepted identity was not reused'; }
grep -qF 'ignoring REDTEAM_ACCEPT_IDENTITIES entry not-an-identity' "$t/out" || { cat "$t/out" >&2; fail 'a malformed entry was not logged'; }
grep -qF "ignoring REDTEAM_ACCEPT_IDENTITIES entry ${original^^}" "$t/out" || { cat "$t/out" >&2; fail 'an uppercase entry was not rejected'; }
REDTEAM_ACCEPT_IDENTITIES="${original^^} ${original:0:63}" run "$t/b" list > "$t/out" 2>&1
grep -qF 'queue [family widgets] acme/widget-shop#7' "$t/out" || { cat "$t/out" >&2; fail 'a malformed accepted identity was honored'; }
echo 'ok REDTEAM_ACCEPT_IDENTITIES carries a receipt across an identity change'

[[ ! -e "$t/danger" ]] || { cat "$t/danger" >&2; fail 'list wrote to the forge'; }
echo 'REVIEW IDENTITY PASS'
