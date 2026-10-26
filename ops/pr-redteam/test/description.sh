#!/usr/bin/env bash
# The reviewer must see a pull request's text as its author wrote it. The forge's
# list of open pull requests (what pr_row reads) carries no text at all; only the
# one-pull-request read does, as `description` (GitHub-style APIs say `body`).
# Every auto-pin bump was held for an "empty" body that was never read
# (jeryu-deploy#243, 2026-10-08/09). Runs pr-redteam's own pr_description against
# a stubbed forge, and the exact jq filters that write description.md and pr.json.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../pr-redteam"
fail() { echo "not ok - $1" >&2; exit 1; }

fn="$(sed -n '/^pr_description() {/,/^}/p' "$script")"
[ -n "$fn" ] || fail "pr_description not found in pr-redteam"
eval "$fn"
desc_filter="$(grep -o "jq -r --arg text \"\$text\" '[^']*'" "$script" | head -1 | sed -e "s/^jq -r --arg text \"\$text\" '//" -e "s/'$//")"
prjson_filter="$(grep -o "jq 'del(\.body[^']*)'" "$script" | head -1 | sed -e "s/^jq '//" -e "s/'$//")"
[ -n "$desc_filter" ] && [ -n "$prjson_filter" ] || fail "description filters not found in pr-redteam"

# A row as the forge's list returns it: no description, no body.
row='{"number":7,"title":"release: pin acme-web 1234567","head_sha":"aaaaaaa","state":"open","available_actions":[]}'

# The stub forge: answers the one-pull-request read with $stub_code and $stub_body.
stub_code=200 stub_body=''
api() { code="$stub_code"; body="$stub_body"; }

stub_body='{"summary":{"number":7,"title":"release: pin acme-web 1234567"},"description":"Pins acme-web main 1234567 so the next staged release ships it."}'
text="$(pr_description acme/deploy 7)"
out="$(jq -r --arg text "$text" "$desc_filter" <<<"$row")"
[[ "$out" == *"Pins acme-web main 1234567"* ]] || fail "the forge's description reaches description.md: $out"
[[ "$out" == "# release: pin acme-web 1234567"* ]] || fail "description.md starts with the title: $out"

stub_body='{"title":"T","body":"github text"}'
[[ "$(pr_description acme/deploy 7)" == "github text" ]] || fail "a GitHub-style body is read"

stub_body='{"summary":{"number":7},"description":null}'
[[ "$(pr_description acme/deploy 7)" == "(no description)" ]] || fail "a pull request with no text says so"

stub_code=503 stub_body='{}'
text="$(pr_description acme/deploy 7)"
[[ "$text" == *"could not be read"*"503"* ]] || fail "a failed read is not reported as an empty description: $text"
[[ "$text" != *"(no description)"* ]] || fail "a failed read never claims the author left it blank"

out="$(jq -c "$prjson_filter" <<<'{"title":"T","body":"x","description":"y","available_actions":[]}')"
[ "$out" = '{"title":"T"}' ] || fail "pr.json carries neither text field: $out"
echo "ok - description.md reads the pull request's own text; a failed read says so; pr.json carries neither"
