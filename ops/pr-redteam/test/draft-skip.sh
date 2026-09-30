#!/usr/bin/env bash
# A draft is skipped, and the skip is said on the pull request's own timeline as
# one `pr.skipped` event per head. `list` and `--dry-run` say what a run would
# do and must post nothing. Only the fixture bearer and a fake curl are used.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
printf 'fixture-bearer\n' > "$t/token"
cat > "$t/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
method=GET data=''
while (($#)); do
  case "$1" in
    --config) [[ "$2" != - ]] || cat > /dev/null; shift ;;
    -X) method="$2"; shift ;;
    --data) data="$2"; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
case "$url" in
  */api/v3/user) printf '{"login":"independent-reviewer"}\n200' ;;
  */api/v1/repos) printf '{"repositories":[{"id":{"owner":"acme","name":"widget-shop"},"family":"widgets","open_pull_requests":1}]}\n200' ;;
  *'/pulls?state=open')
    printf '{"items":[{"repo":{"owner":"acme","name":"widget-shop"},"number":7,"head_sha":"dddddddddddddddddddddddddddddddddddddddd","base_sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","head_ref":"cart-totals","base_ref":"rc/auto","draft":true,"author":"dana","title":"cart totals","state":"open"}]}\n200' ;;
  */api/v1/events) printf '%s\n' "$data" >> "$DRAFT_FIXTURE/posted"; printf '{"ok":true,"seqs":[1],"duplicates":0}\n201' ;;
  *) printf '{"message":"unexpected %s %s"}\n404' "$method" "$url" ;;
esac
FIXTURE
chmod +x "$t/bin/curl"

run() { # command extra-args…
  DRAFT_FIXTURE="$t" PATH="$t/bin:$PATH" JERYU_TOKEN_FILE="$t/token" \
    REDTEAM_STATE="$t/state" REDTEAM_FAMILIES=all "$here/pr-redteam" "$@" > "$t/out" 2>&1
}

run list
grep -qF 'skip acme/widget-shop#7 — draft' "$t/out" || { cat "$t/out" >&2; echo 'list did not name the draft skip' >&2; exit 1; }
[[ ! -e "$t/posted" ]] || { echo 'list posted an event' >&2; exit 1; }

run run --dry-run
[[ ! -e "$t/posted" ]] || { echo '--dry-run posted an event' >&2; exit 1; }

run run
[[ -s "$t/posted" ]] || { cat "$t/out" >&2; echo 'a run posted nothing for the draft' >&2; exit 1; }
[[ "$(wc -l < "$t/posted")" == 1 ]] || { echo 'more than one event per run' >&2; exit 1; }
check() { # jq-filter expected
  local got; got="$(jq -r "$1" "$t/posted")"
  [[ "$got" == "$2" ]] || { echo "$1: expected $2, got $got" >&2; exit 1; }
}
check .kind pr.skipped
check .source pr-redteam
check .repo acme/widget-shop
check .pr 7
check .sha dddddddddddddddddddddddddddddddddddddddd
check .outcome skipped
check .detail.skipped draft
check .detail.automation pr-redteam
check .summary 'pr-redteam skipped acme/widget-shop#7: draft'
# The event_id carries the head, so the forge keeps one line however many passes
# see the same draft: the second run posts the same body and stores nothing new.
check .event_id 'pr-redteam:dddddddddddddddddddddddddddddddddddddddd:skipped-draft'
first="$(cat "$t/posted")"
run run
[[ "$(wc -l < "$t/posted")" == 2 ]] || { echo 'the second run posted a different number of events' >&2; exit 1; }
[[ "$(tail -1 "$t/posted")" == "$first" ]] || { echo 'the second run posted a different body' >&2; exit 1; }
echo 'DRAFT SKIP PASS'
