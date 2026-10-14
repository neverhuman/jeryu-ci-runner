#!/usr/bin/env bash
# Every heartbeat body must fit the forge's contract, which denies unknown fields at every level:
# jeryu-deploy crates/jeryu-api/src/web/control_plane/gate_runners.rs (GateRunnerHeartbeat,
# GateRunnerTask, GateRunnerResult, RunnerCode, RunnerTool). One stray key refuses the whole beat
# with 422, which is how every busy beat was lost: the slot bookkeeping in beats/current/<key>.json
# went out inside `current`. The fake forge here applies the same key rules and the reviewer
# conclusion list, and the beats must also carry the code and CLI the reviewer runs.
set -euo pipefail
umask 077
src="$(cd "$(dirname "$0")/.." && pwd)"
real_git="$(command -v git)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
# The contract, as jq over one body. Prints nothing when the body is accepted.
cat > "$t/contract.jq" <<'JQ'
def only($allowed): keys - $allowed;
def need($required): $required - keys;
def problems($what; $allowed; $required):
  (only($allowed) | map("\($what): unknown field \(.)")) + (need($required) | map("\($what): missing \(.)"));
(problems("beat"; ["runnerId","host","slot","labels","intervalSeconds","current","last","code","tools"];
          ["runnerId","host","slot"]))
+ (if .current == null then [] else (.current | problems("current";
      ["repo","pr","sha","recipe","target","startedAt","started_at"]; ["repo","sha","recipe"])
    + (if has("startedAt") or has("started_at") then [] else ["current: missing startedAt"] end)) end)
+ (if .last == null then [] else (.last | problems("last";
      ["repo","pr","sha","recipe","conclusion","target","reason","seconds","finishedAt","finished_at"];
      ["repo","sha","recipe","conclusion","seconds"])
    + (if has("finishedAt") or has("finished_at") then [] else ["last: missing finishedAt"] end)
    + (.conclusion as $c | if (["approve","hold","failed","interrupted","publication_rejected","too_large"] | index($c)) == null
       then ["last.conclusion: \(.conclusion) is not a reviewer conclusion"] else [] end)) end)
+ (if .code == null then [] else (.code | problems("code"; ["repo","commit","version","installedAt","installed_at"]; ["repo","commit"])
    + (if (.commit | type) == "string" and (.commit | test("^[0-9a-f]{7,64}$")) then [] else ["code.commit: not 7-64 lowercase hex"] end)) end)
+ ((.tools // []) | to_entries | map(.value | problems("tools[\(.key)]"; ["name","version","sha256"]; ["name"])) | add // [])
| .[]
JQ
cat > "$t/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
cat > /dev/null; data=''
while (($#)); do [[ "$1" != --data ]] || data="$2"; shift; done
printf '%s\n' "$data" >> "$HEARTBEAT_SENT"
problems="$(jq -r -f "$HEARTBEAT_CONTRACT" <<<"$data")"
if [[ -n "$problems" ]]; then
  printf '%s\n' "$problems" >> "$HEARTBEAT_REFUSED"
  printf '{"message":"the request body is not valid JSON for this route"}\n422'
else
  printf '{"accepted":true}\n200'
fi
FIXTURE
cat > "$t/bin/systemctl" <<'FIXTURE'
#!/usr/bin/env bash
case "$*" in *' -p Result '*) echo success ;; *) exit 2 ;; esac
FIXTURE
chmod +x "$t/bin/"*
printf 'fixture-bearer\n' > "$t/token"
beat() { # source-dir
  : > "$t/sent"; : > "$t/refused"
  HEARTBEAT_SENT="$t/sent" HEARTBEAT_REFUSED="$t/refused" HEARTBEAT_CONTRACT="$t/contract.jq" \
    PATH="$t/bin:$PATH" JERYU_BASE=https://forge.invalid JERYU_TOKEN_FILE="$t/token" \
    REDTEAM_STATE="$t/state" REDTEAM_RUNNER_ID=fixture/redteam REDTEAM_JOBS=2 \
    "$1/pr-redteam" heartbeat > "$t/out" 2>&1
}
accepted() {
  [[ ! -s "$t/refused" && ! -s "$t/out" ]] || { echo "refused: $(cat "$t/refused" "$t/out")" >&2; exit 1; }
  [[ "$(grep -c . "$t/sent")" == 2 ]] || { echo "expected two beats: $(cat "$t/sent")" >&2; exit 1; }
}

# The fake forge refuses what the real one refused: a current file carrying `slot`.
probe='{"runnerId":"fixture/redteam","host":"h","slot":0,"current":{"repo":"jeryu/jeryu-web","pr":7,"sha":"abcdef1","recipe":"redteam-review","started_at":"2026-10-14T15:00:00Z","slot":0}}'
[[ "$(jq -r -f "$t/contract.jq" <<<"$probe")" == 'current: unknown field slot' ]]
echo 'ok the fixture refuses the slot key'

# An install is a `git archive` export: source-commit carries the exported commit.
"$real_git" init -q -b main "$t/repo"
cp -R "$src" "$t/repo/pr-redteam-src"
g() { "$real_git" -C "$t/repo" -c user.name=fixture -c user.email=fixture@example.invalid "$@"; }
g add .; g commit -qm fixture
commit="$(g rev-parse HEAD)"
mkdir -p "$t/export"
g archive "$commit" pr-redteam-src | tar -x -C "$t/export"
[[ "$(cat "$t/export/pr-redteam-src/source-commit")" == "$commit" ]]

# A busy slot 0, a finished review on slot 1 whose receipt decision the forge has no word for, and
# the CLI version the last review measured.
mkdir -p "$t/state/beats/slots" "$t/state/beats/current"
printf 'jeryu_jeryu-web-7\n' > "$t/state/beats/slots/0"
jq -nc '{repo:"jeryu/jeryu-web", pr:7, sha:"0123456789abcdef0123456789abcdef01234567",
         recipe:"redteam-review", started_at:"2026-10-14T15:00:00Z", slot:0}' \
  > "$t/state/beats/current/jeryu_jeryu-web-7.json"
jq -nc '{repo:"jeryu/jeryu-web", pr:8, sha:"89abcdef0123456789abcdef0123456789abcdef",
         recipe:"redteam-review", conclusion:"base_missing", seconds:3, finished_at:"2026-10-14T14:00:00Z"}' \
  > "$t/state/beats/last-1.json"
printf '9.9.9\n' > "$t/state/beats/claude-version"
beat "$t/export/pr-redteam-src"
accepted
row0="$(sed -n 1p "$t/sent")"; row1="$(sed -n 2p "$t/sent")"
jq -e '.current == {repo:"jeryu/jeryu-web", pr:7, sha:"0123456789abcdef0123456789abcdef01234567",
                    recipe:"redteam-review", started_at:"2026-10-14T15:00:00Z"}' <<<"$row0" >/dev/null
echo 'ok a busy beat reports its review and is accepted'
jq -e '.last.conclusion == "hold" and (.last.reason | startswith("base_missing:")) and .last.pr == 8' <<<"$row1" >/dev/null
echo 'ok a review left for a person is reported as hold with its reason'
jq -e --arg c "$commit" '.code == {repo:"jeryu/jeryu-ci-runner", commit:$c}' <<<"$row0" >/dev/null
jq -e --arg c "$commit" '.code.commit == $c' <<<"$row1" >/dev/null
jq -e '.tools == [{name:"claude", version:"9.9.9"}]' <<<"$row0" >/dev/null
echo 'ok code is the exported commit and tools is the measured CLI'

# A clean git checkout reports its HEAD; a modified one, and a copy with no record, report no code.
beat "$t/repo/pr-redteam-src"
accepted
jq -e --arg c "$commit" '.code.commit == $c' <<<"$(sed -n 1p "$t/sent")" >/dev/null
printf '# local edit\n' >> "$t/repo/pr-redteam-src/prompt.md"
beat "$t/repo/pr-redteam-src"
accepted
jq -e 'has("code") | not' <<<"$(sed -n 1p "$t/sent")" >/dev/null
cp -R "$src" "$t/plain"
rm -f "$t/state/beats/claude-version"
beat "$t/plain"
accepted
jq -e '(has("code") | not) and .tools == []' <<<"$(sed -n 1p "$t/sent")" >/dev/null
echo 'ok unknown code is left out'
echo 'HEARTBEAT CONTRACT PASS'
