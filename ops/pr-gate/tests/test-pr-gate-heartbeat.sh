#!/usr/bin/env bash
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
source_file="$script_dir/pr-gate-heartbeat.sh"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/home/attempts/key/attempt" "$fixture/home/cache"
printf 'FAKE-REVIEW-TOKEN\n' > "$fixture/token"
chmod 0600 "$fixture/token"
cat > "$fixture/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --disable && "$*" != *FAKE-REVIEW-TOKEN* ]]
config='' data='' url=''
while (($#)); do
  case "$1" in
    --config) config=$2; shift 2 ;;
    --data) data=$2; shift 2 ;;
    --data-binary) [[ "$2" == @- ]]; data=$(cat); shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
[[ "$(stat -c '%a' "$config")" == 600 ]]
printf '%s\n' "$config" >> "$HEARTBEAT_TEST_AUTH_PATHS"
jq -nc --arg url "$url" --argjson body "$data" '{url:$url,body:$body}' >> "$HEARTBEAT_TEST_CAPTURE"
if [[ "${HEARTBEAT_TEST_HTTP:-200}" == transport ]]; then exit 7; fi
if [[ "$url" == */api/v1/events ]]; then
  if [[ "${HEARTBEAT_TEST_EVENT_HTTP:-200}" == html ]]; then printf '<!doctype html><html></html>\n200'; exit 0; fi
  printf '{"ok":true}\n%s' "${HEARTBEAT_TEST_EVENT_HTTP:-200}"; exit 0
fi
if [[ -n "${HEARTBEAT_TEST_REJECT_TOOLS:-}" ]] && jq -e 'has("tools")' <<<"$data" >/dev/null; then
  printf 'Failed to deserialize the JSON body: unknown field `tools`\n422'; exit 0
fi
if [[ -n "${HEARTBEAT_TEST_REJECT_CODE:-}" ]] && jq -e 'has("code")' <<<"$data" >/dev/null; then
  printf 'Failed to deserialize the JSON body: unknown field `code`\n422'; exit 0
fi
printf '{"accepted":true}\n%s' "${HEARTBEAT_TEST_HTTP:-200}"
CURL
cat > "$fixture/bin/journalctl" <<'JOURNAL'
#!/usr/bin/env bash
printf 'preparing jeryu/jeryu-tool#4 at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
JOURNAL
chmod +x "$fixture/bin/curl" "$fixture/bin/journalctl"
export HEARTBEAT_TEST_CAPTURE="$fixture/capture.jsonl" HEARTBEAT_TEST_AUTH_PATHS="$fixture/auth-paths"
# The site configuration names the forge and the code repo; the credential comes from the environment.
printf 'PR_GATE_FORGE_URL=https://forge.example.test/\nPR_GATE_CODE_REPO="acme/gate-code"\n' >"$fixture/pr-gate.env"
export PR_GATE_CONFIG="$fixture/pr-gate.env"
export PATH="$fixture/bin:$PATH" JERYU_BASE=https://forge.example.test JERYU_TOKEN_FILE="$fixture/token"
export GATE_RUNNER_HOME="$fixture/home" GATE_RUNNER_SLOTS=0
: > "$HEARTBEAT_TEST_CAPTURE"
refuse() {
  local before
  before=$(wc -l < "$HEARTBEAT_TEST_CAPTURE")
  if "$@" > "$fixture/refusal.log" 2>&1; then printf 'expected heartbeat refusal\n' >&2; exit 1; fi
  [[ "$(wc -l < "$HEARTBEAT_TEST_CAPTURE")" == "$before" ]]
}
refuse env JERYU_BASE=https://foreign.invalid JERYU_TOKEN_FILE="$fixture/missing" bash "$source_file"
refuse env JERYU_BASE=https://forge.example.test.foreign.invalid bash "$source_file"
refuse env -u JERYU_BASE PR_GATE_CONFIG=/nonexistent bash "$source_file"
refuse env JERYU_TOKEN_FILE= bash "$source_file"
for token in '' 'invalid"bearer' $'invalid\rbearer' $'invalid\nbearer'; do
  printf '%s' "$token" > "$fixture/invalid-token"; chmod 0600 "$fixture/invalid-token"
  refuse env JERYU_TOKEN_FILE="$fixture/invalid-token" bash "$source_file"
done
chmod 0644 "$fixture/invalid-token"
refuse env JERYU_TOKEN_FILE="$fixture/invalid-token" bash "$source_file"
ln -s "$fixture/token" "$fixture/token-link"
refuse env JERYU_TOKEN_FILE="$fixture/token-link" bash "$source_file"
printf 'PASS foreign/lookalike origins and invalid credential files cannot publish\n'
receipt="$fixture/home/attempts/key/attempt/receipt.json"
jq -nc --argjson pid "$$" '{slot:"0",terminal:false,boot_id:"00000000-0000-0000-0000-000000000000",pid:$pid,worker_pid:$pid,owner:"jeryu",repo:"jeryu-tool",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",started_at:"2026-01-01T00:00:00Z",inputs:{recipe:"ops/ci/pr-ci.sh"}}' > "$receipt"
bash "$source_file"
tail -1 "$HEARTBEAT_TEST_CAPTURE" | jq -e '.body.current==null' >/dev/null
printf 'PASS previous-boot receipt cannot appear busy\n'
jq --arg boot "$(cat /proc/sys/kernel/random/boot_id)" '.boot_id=$boot' "$receipt" > "$fixture/new.json"
mv "$fixture/new.json" "$receipt"
bash "$source_file" 2> "$fixture/recovery.log"
tail -1 "$HEARTBEAT_TEST_CAPTURE" | jq -e '.body.current==null' >/dev/null
grep -q 'recovery required' "$fixture/recovery.log"
printf 'PASS same-boot PID reuse requires visible recovery\n'
jq --arg at "$(date -u +%FT%TZ)" '.started_at=$at' "$receipt" > "$fixture/new.json"
mv "$fixture/new.json" "$receipt"
bash "$source_file"
tail -1 "$HEARTBEAT_TEST_CAPTURE" | jq -e '.body.current.recipe=="ops/ci/pr-ci.sh" and .body.current.pr==4 and .body.current.repo=="jeryu/jeryu-tool"' >/dev/null
printf 'PASS current controller receipt preserves actual recipe and PR\n'
for conclusion in success failure timed_out inputs_changed; do
  jq -nc --arg conclusion "$conclusion" '{repo:"jeryu/jeryu-tool",pr:4,sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",recipe:"ops/ci/pr-ci.sh",seconds:4,finishedAt:"2026-09-18T00:00:00Z",exit_code:7,conclusion:$conclusion}' > "$fixture/home/cache/slot-0-last.json"
  bash "$source_file"
  expected=$conclusion
  [[ "$conclusion" == success || "$conclusion" == failure ]] || expected=error
  tail -1 "$HEARTBEAT_TEST_CAPTURE" | jq -e --arg expected "$expected" '.body.last.conclusion==$expected and (.body.last|has("exit_code")|not)' >/dev/null
done
printf 'PASS last-result projection keeps the supported conclusion schema\n'
sha256sum "$receipt" "$fixture/home/cache/slot-0-last.json" > "$fixture/inputs.sha256"
HEARTBEAT_TEST_HTTP=403 bash "$source_file" 2> "$fixture/denied.log"
grep -q 'heartbeat answered 403' "$fixture/denied.log"
HEARTBEAT_TEST_HTTP=transport bash "$source_file" 2> "$fixture/transport.log"
grep -q 'heartbeat answered 000' "$fixture/transport.log"
sha256sum -c "$fixture/inputs.sha256" >/dev/null
while IFS= read -r auth_path; do [[ ! -e "$auth_path" ]]; done < "$HEARTBEAT_TEST_AUTH_PATHS"
printf 'PASS rejection/transport errors are visible; source receipts are unchanged; private auth configs are removed\n'

# ---- finished attempts become pipeline events ----------------------------------------------------
events() { jq -c 'select(.url | endswith("/api/v1/events")) | .body' "$HEARTBEAT_TEST_CAPTURE"; }
[[ -z "$(events)" ]]
printf 'PASS a running attempt posts no event\n'
attempt_dir=$(dirname "$receipt")
{ printf 'early line that must fall outside the tail\n'; head -c 20000 /dev/zero | tr '\0' 'x'; printf '\n\033[31merror\033[0m: test failed\r\nlast line\n'; } > "$attempt_dir/build.log"
jq '.terminal=true | .outcome="failure" | .exit_code=101 | .id="attempt-1" | .sequence=1 | .execution_kind="operator-unsealed" | .cache="none"
    | .log="/etc/passwd" | .recovery_required=null | .finished_at=(.started_at | fromdateiso8601 + 65 | todateiso8601)
    | .inputs.required_context="jeryu-tool/required"' "$receipt" > "$fixture/new.json"
mv "$fixture/new.json" "$receipt"
jq -nc '{repo:"jeryu/jeryu-tool",pr:4,sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",recipe:"ops/ci/pr-ci.sh",seconds:65,finishedAt:"2026-09-18T00:00:00Z",exit_code:101,conclusion:"failure"}' > "$fixture/home/cache/slot-0-last.json"
sha256sum "$receipt" "$attempt_dir/build.log" > "$fixture/evidence.sha256"
HEARTBEAT_TEST_EVENT_HTTP=html bash "$source_file" 2> "$fixture/no-route.log"
grep -q 'event log answered unacknowledged' "$fixture/no-route.log"
[[ ! -e "$fixture/home/cache/events-posted/attempt-1" ]]
HEARTBEAT_TEST_EVENT_HTTP=503 bash "$source_file" 2> "$fixture/outage.log"
grep -q 'event log answered 503' "$fixture/outage.log"
[[ ! -e "$fixture/home/cache/events-posted/attempt-1" ]]
printf 'PASS a forge without the event route (200 + HTML) or in an outage leaves the attempt unreported for a later tick\n'
: > "$HEARTBEAT_TEST_CAPTURE"
bash "$source_file"
[[ "$(events | wc -l)" == 1 ]]
events | jq -e '.event_id=="pr-gate:attempt-1" and .source=="pr-gate" and .kind=="gate.log" and .repo=="jeryu/jeryu-tool" and .pr==4 and .outcome=="failure"
  and .seconds==65 and .needs_human==false and .reason==null and .actor==(.actor|tostring) and (.actor|endswith("/slot0"))
  and (.summary|test("jeryu/jeryu-tool#4 jeryu-tool/required failure in 65s"))
  and .detail.attempt=="attempt-1" and .detail.exit_code==101 and .detail.recipe=="ops/ci/pr-ci.sh" and .detail.log_bytes>20000
  and .detail.cache=="none"
  and (.log_tail|endswith("error: test failed\nlast line\n")) and (.log_tail|contains("early line")|not)
  and (.log_tail|contains("root:")|not) and (.log_tail|test("\u001b|\r")|not) and ((.log_tail|utf8bytelength) <= 12288)' >/dev/null
[[ -e "$fixture/home/cache/events-posted/attempt-1" ]]
printf 'PASS a finished attempt posts one gate.log event with a cleaned log tail taken from beside the receipt\n'
bash "$source_file"
[[ "$(events | wc -l)" == 1 ]]
printf 'PASS an attempt is reported once\n'
jq '.id="attempt-2" | .outcome="inputs_changed" | .recovery_required="publication rejected; rerun gate_publish"' "$receipt" > "$attempt_dir/../receipt2.json"
mkdir -p "$fixture/home/attempts/key/attempt2"; mv "$attempt_dir/../receipt2.json" "$fixture/home/attempts/key/attempt2/receipt.json"
HEARTBEAT_TEST_EVENT_HTTP=422 bash "$source_file" 2> "$fixture/rejected.log"
grep -q 'attempt attempt-2: event rejected 422' "$fixture/rejected.log"
[[ -e "$fixture/home/cache/events-posted/attempt-2.rejected" ]]
events | tail -1 | jq -e '.outcome=="inputs_changed" and .needs_human==true and (.reason|startswith("publication rejected")) and .log_tail==null' >/dev/null
before=$(events | wc -l); bash "$source_file"; [[ "$(events | wc -l)" == "$before" ]]
printf 'PASS recovery_required is flagged for a human; a 422 is recorded once and not retried\n'
before=$(events | wc -l)
rm -f "$fixture/home/cache/events-posted/"*
GATE_RUNNER_EVENTS=0 bash "$source_file"
[[ "$(events | wc -l)" == "$before" ]]
printf 'PASS GATE_RUNNER_EVENTS=0 posts nothing\n'
sha256sum -c "$fixture/evidence.sha256" >/dev/null
printf 'PASS attempt evidence is unchanged by reporting\n'

# A receipt from a runner that predates the cache field still projects, with detail.cache null; one
# that compiled with sccache forwards that, so the Activity feed can tell a cached gate from an
# uncached one.
rm -f "$fixture/home/cache/events-posted/"*
: > "$HEARTBEAT_TEST_CAPTURE"
jq '.id="attempt-3" | .cache="sccache"' "$receipt" > "$fixture/home/attempts/key/attempt2/receipt.json"
jq 'del(.cache) | .id="attempt-4"' "$receipt" > "$fixture/new.json"
mv "$fixture/new.json" "$receipt"
bash "$source_file"
events | jq -se 'map({(.detail.attempt): .detail.cache}) | add
  | .["attempt-3"]=="sccache" and .["attempt-4"]==null' >/dev/null
printf 'PASS detail.cache is forwarded, and a receipt without it still reports\n'

# ---- the code each runner runs ---------------------------------------------------------------------
heartbeats() { jq -c 'select(.url | endswith("/api/v1/runners/heartbeat")) | .body' "$HEARTBEAT_TEST_CAPTURE"; }
installed="$fixture/home/installed-main.json"
: > "$HEARTBEAT_TEST_CAPTURE"
bash "$source_file"
heartbeats | jq -se 'length==1 and (.[0]|has("code")|not)' >/dev/null
printf 'PASS no installed-main.json: the heartbeat carries no code key\n'
for bad in '{"commit":"main"}' '{"commit":"abc123"}' 'not json' '{"verified_at":"2026-10-01T00:00:00Z"}'; do
  printf '%s\n' "$bad" > "$installed"
  : > "$HEARTBEAT_TEST_CAPTURE"
  bash "$source_file"
  heartbeats | jq -se 'length==1 and (.[0]|has("code")|not)' >/dev/null
done
printf 'PASS an unreadable or non-hex installed commit sends no code key\n'
commit=0123456789abcdef0123456789abcdef01234567
jq -nc --arg c "$commit" '{commit:$c,previous:"fedcba9",installed_at:"2026-10-01T01:02:03Z",files:["scripts/pr-gate-runner.sh"]}' > "$installed"
: > "$HEARTBEAT_TEST_CAPTURE"
bash "$source_file"
heartbeats | jq -se --arg c "$commit" 'length==1 and .[0].code=={repo:"acme/gate-code",commit:$c,installedAt:"2026-10-01T01:02:03Z"}
  and .[0].runnerId==(.[0].host + "/slot0")' >/dev/null
jq -nc --arg c "$commit" '{commit:$c,verified_at:"2026-10-01T04:05:06Z"}' > "$installed"
: > "$HEARTBEAT_TEST_CAPTURE"
PR_GATE_CODE_REPO=example/runner-code bash "$source_file"
heartbeats | jq -se --arg c "$commit" '.[0].code=={repo:"example/runner-code",commit:$c,installedAt:"2026-10-01T04:05:06Z"}' >/dev/null
: > "$HEARTBEAT_TEST_CAPTURE"
PR_GATE_CODE_REPO='' bash "$source_file"
heartbeats | jq -se 'length==1 and (.[0]|has("code")|not)' >/dev/null \
  || { printf 'FAIL: code was reported without a configured code repo\n' >&2; exit 1; }
printf 'PASS installed-main.json becomes code {repo, commit, installedAt}; PR_GATE_CODE_REPO names the repo, and without one no code is sent\n'
version="pr-gate 1.0.0"
jq -nc --arg c "$commit" --arg v "$version" '{commit:$c,verified_at:"2026-10-01T04:05:06Z",version:$v}' > "$installed"
: > "$HEARTBEAT_TEST_CAPTURE"
bash "$source_file"
heartbeats | jq -se --arg c "$commit" --arg v "$version" \
  '.[0].code=={repo:"acme/gate-code",commit:$c,installedAt:"2026-10-01T04:05:06Z",version:$v}' >/dev/null
long=$(printf 'v%.0s' {1..101})
for bad in '""' '7' '["v1"]' '"pr-gate 1.0.0\nsecond line"' '"tab\there"' "\"$long\""; do
  jq -nc --arg c "$commit" --argjson v "$bad" '{commit:$c,installed_at:"2026-10-01T01:02:03Z",version:$v}' > "$installed"
  : > "$HEARTBEAT_TEST_CAPTURE"
  bash "$source_file"
  heartbeats | jq -se --arg c "$commit" '.[0].code=={repo:"acme/gate-code",commit:$c,installedAt:"2026-10-01T01:02:03Z"}' >/dev/null \
    || { printf 'FAIL: version %s was not omitted\n' "$bad" >&2; exit 1; }
done
printf 'PASS a recorded version is passed through as code.version; an empty, non-string, too long or control-char one is omitted\n'
: > "$HEARTBEAT_TEST_CAPTURE"
GATE_RUNNER_SLOTS="0 1" HEARTBEAT_TEST_REJECT_CODE=1 bash "$source_file" 2> "$fixture/code-422.log"
heartbeats | jq -se 'length==3 and (.[0]|has("code")) and .[0].slot==0 and (.[1]|has("code")|not) and .[1].slot==0
  and (.[2]|has("code")|not) and .[2].slot==1' >/dev/null
[[ "$(grep -c 'heartbeat code refused (422); retrying without it' "$fixture/code-422.log")" == 1 ]]
if grep -q 'heartbeat answered' "$fixture/code-422.log"; then cat "$fixture/code-422.log" >&2; exit 1; fi
printf 'PASS a forge that refuses code with 422 gets the same heartbeat without it, logged once per tick\n'

# ---- what each runner evaluates with ---------------------------------------------------------------
tools_file="$fixture/home/tools.json"
sha_a=$(printf 'a%.0s' {1..64}) sha_b=$(printf 'b%.0s' {1..64})
: > "$HEARTBEAT_TEST_CAPTURE"
bash "$source_file"
heartbeats | jq -se 'length==1 and (.[0]|has("tools")|not)' >/dev/null
for bad in 'not json' '{"tools":"x"}' '{"tools":[]}' '{"tools":[{"name":"Bad"}]}' '[]'; do
  printf '%s\n' "$bad" > "$tools_file"
  : > "$HEARTBEAT_TEST_CAPTURE"
  bash "$source_file"
  heartbeats | jq -se 'length==1 and (.[0]|has("tools")|not)' >/dev/null || { printf 'FAIL: tools %s sent\n' "$bad" >&2; exit 1; }
done
printf 'PASS no, unreadable or empty tools.json: the heartbeat carries no tools key\n'
long=$(printf 'v%.0s' {1..101}) longname=$(printf 'n%.0s' {1..65})
jq -nc --arg a "$sha_a" --arg b "$sha_b" --arg long "$long" --arg ln "$longname" '{generated_at:"2026-10-01T00:00:00Z", tools:[
  {name:"jankurai",version:"1.6.11",sha256:$a},
  {name:"jankurai@governed",version:"1.6.10",sha256:$b},
  {name:"gitleaks"},
  {name:"jankurai",version:"duplicate"},
  {name:"UPPER",version:"1"}, {name:"sp ace"}, {name:""}, {name:$ln}, {name:7}, "str", null,
  {name:"badver",version:$long,sha256:"ABC"}, {name:"ctl",version:"a\nb",sha256:($a|ascii_upcase)}]}' > "$tools_file"
: > "$HEARTBEAT_TEST_CAPTURE"
bash "$source_file"
heartbeats | jq -se --arg a "$sha_a" --arg b "$sha_b" 'length==1 and .[0].tools==[
  {name:"jankurai",version:"1.6.11",sha256:$a}, {name:"jankurai@governed",version:"1.6.10",sha256:$b},
  {name:"gitleaks"}, {name:"badver"}, {name:"ctl"}]
  and .[0].code.commit=="'"$commit"'"' >/dev/null
jq -nc '{tools:[range(40) | {name:("t" + tostring)}]}' > "$tools_file"
: > "$HEARTBEAT_TEST_CAPTURE"
bash "$source_file"
heartbeats | jq -se '.[0].tools|length==32' >/dev/null
printf 'PASS tools.json becomes tools[]: invalid names dropped, invalid version/sha256 omitted, names unique, at most 32\n'
printf '{"tools":[{"name":"jankurai","version":"1.6.11"}]}\n' > "$tools_file"
: > "$HEARTBEAT_TEST_CAPTURE"
GATE_RUNNER_SLOTS="0 1" HEARTBEAT_TEST_REJECT_TOOLS=1 bash "$source_file" 2> "$fixture/tools-422.log"
heartbeats | jq -se 'length==3 and (.[0]|has("tools") and has("code")) and (.[1]|(has("tools")|not) and has("code")) and .[1].slot==0
  and (.[2]|(has("tools")|not) and has("code")) and .[2].slot==1' >/dev/null
[[ "$(grep -c 'heartbeat tools refused (422); retrying without them' "$fixture/tools-422.log")" == 1 ]]
if grep -q 'heartbeat code refused\|heartbeat answered' "$fixture/tools-422.log"; then cat "$fixture/tools-422.log" >&2; exit 1; fi
: > "$HEARTBEAT_TEST_CAPTURE"
GATE_RUNNER_SLOTS="0 1" HEARTBEAT_TEST_REJECT_TOOLS=1 HEARTBEAT_TEST_REJECT_CODE=1 bash "$source_file" 2> "$fixture/both-422.log"
heartbeats | jq -se 'length==4 and (.[0]|has("tools") and has("code")) and (.[1]|(has("tools")|not) and has("code"))
  and (.[2]|has("tools") or has("code")|not) and .[2].slot==0 and (.[3]|has("tools") or has("code")|not) and .[3].slot==1' >/dev/null
[[ "$(grep -c 'heartbeat tools refused (422); retrying without them' "$fixture/both-422.log")" == 1 ]]
[[ "$(grep -c 'heartbeat code refused (422); retrying without it' "$fixture/both-422.log")" == 1 ]]
if grep -q 'heartbeat answered' "$fixture/both-422.log"; then cat "$fixture/both-422.log" >&2; exit 1; fi
printf 'PASS a 422 retries without tools (keeping code), then without code too; each logged once per tick\n'
