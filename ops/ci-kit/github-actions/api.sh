#!/usr/bin/env bash
# Root-only app transport. Tokens and JIT configs travel on private fds/stdin.
set -euo pipefail
[[ $(id -u) == 0 ]] || exit 2
config=/etc/neverhuman-actions/app.json
key=/etc/neverhuman-actions/app-key.pem
for file in "$config" "$key"; do
  [[ $(stat -c '%a %U' "$file") == '600 root' ]] || { echo 'Controller credential permission mismatch' >&2; exit 2; }
done
app=$(jq -er '.app_id | tostring | select(test("^[0-9]+$"))' "$config")
installation=$(jq -er '.installation_id | tostring | select(test("^[0-9]+$"))' "$config")
method=${1:?method required}
endpoint=${2:?endpoint required}
case "$method $endpoint" in
  'GET /orgs/neverhuman/actions/runners'|'GET /orgs/neverhuman/actions/runner-groups'|'POST /orgs/neverhuman/actions/runners/generate-jitconfig') ;;
  *) echo 'API operation outside controller scope' >&2; exit 2 ;;
esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(jq -nc --arg iss "$app" --argjson iat "$((now - 60))" --argjson exp "$((now + 540))" \
  '{iss:$iss,iat:$iat,exp:$exp}' | b64url)
signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" | b64url)
jwt=$header.$payload.$signature
curl -fsS --retry 3 -X POST -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2026-03-10' -K <(printf 'header = "Authorization: Bearer %s"\n' "$jwt") \
  "https://api.github.com/app/installations/$installation/access_tokens" \
  --data '{"permissions":{"organization_self_hosted_runners":"write"}}' --output "$tmp/access.json"
token=$(jq -er '.token' "$tmp/access.json")
args=(-fsS --retry 3 -X "$method" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2026-03-10')
[[ $method != POST ]] || args+=(--data-binary @-)
curl "${args[@]}" -K <(printf 'header = "Authorization: Bearer %s"\n' "$token") "https://api.github.com$endpoint"
