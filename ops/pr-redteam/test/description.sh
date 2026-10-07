#!/usr/bin/env bash
# The reviewer must see a pull request's text whichever field the forge uses: the
# forge's v1 API returns it as `description`, GitHub-style APIs as `body`. Runs the
# exact jq filters pr-redteam uses to build description.md and pr.json.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../pr-redteam"
desc_filter="$(grep -o "jq -r '\"# .*(no description)\")\"'" "$script" | head -1 | sed -e "s/^jq -r '//" -e "s/'$//")"
prjson_filter="$(grep -o "jq 'del(\.body[^']*)'" "$script" | head -1 | sed -e "s/^jq '//" -e "s/'$//")"
[ -n "$desc_filter" ] && [ -n "$prjson_filter" ] || { echo "description filters not found in pr-redteam" >&2; exit 1; }
fail() { echo "not ok - $1" >&2; exit 1; }
out="$(jq -r "$desc_filter" <<<'{"title":"T","body":null,"description":"forge text"}')"
[[ "$out" == *"forge text"* ]] || fail "forge description is shown"
out="$(jq -r "$desc_filter" <<<'{"title":"T","body":"github text"}')"
[[ "$out" == *"github text"* ]] || fail "github body is shown"
out="$(jq -r "$desc_filter" <<<'{"title":"T","body":null,"description":null}')"
[[ "$out" == *"(no description)"* ]] || fail "a missing description says so"
out="$(jq -c "$prjson_filter" <<<'{"title":"T","body":"x","description":"y","available_actions":[]}')"
[ "$out" = '{"title":"T"}' ] || fail "pr.json carries neither text field: $out"
echo "ok - description.md reads body or description; pr.json carries neither"
