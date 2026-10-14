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
# OLD_FORGE: a forge whose contract predates `code` and `tools`.
if [[ -n "${OLD_FORGE:-}" ]]; then
  problems+="$(jq -r 'if has("code") or has("tools") then "beat: unknown field code/tools" else empty end' <<<"$data")"
fi
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
mkdir -p "$t/repo/ops"
cp -R "$src" "$t/repo/ops/pr-redteam"
"$real_git" -C "$t/repo" remote add origin https://forge.invalid/git/jeryu/jeryu-ci-runner.git
g() { "$real_git" -C "$t/repo" -c user.name=fixture -c user.email=fixture@example.invalid "$@"; }
g add .; g commit -qm fixture
commit="$(g rev-parse HEAD)"
mkdir -p "$t/export"
g archive "$commit" | tar -x -C "$t/export"
[[ "$(cat "$t/export/ops/pr-redteam/source-commit")" == "$commit" ]]

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
beat "$t/export/ops/pr-redteam"
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

# A clean git checkout of this repository reports its HEAD; a modified one, a checkout of another
# repository, and a copy with no record report no code, and no `tools` before the first review.
beat "$t/repo/ops/pr-redteam"
accepted
jq -e --arg c "$commit" '.code.commit == $c' <<<"$(sed -n 1p "$t/sent")" >/dev/null
"$real_git" -C "$t/repo" remote set-url origin https://forge.invalid/git/acme/other.git
beat "$t/repo/ops/pr-redteam"
accepted
jq -e 'has("code") | not' <<<"$(sed -n 1p "$t/sent")" >/dev/null
"$real_git" -C "$t/repo" remote set-url origin https://forge.invalid/git/jeryu/jeryu-ci-runner.git
printf '# local edit\n' >> "$t/repo/ops/pr-redteam/prompt.md"
beat "$t/repo/ops/pr-redteam"
accepted
jq -e 'has("code") | not' <<<"$(sed -n 1p "$t/sent")" >/dev/null
cp -R "$src" "$t/plain"
rm -f "$t/state/beats/claude-version"
beat "$t/plain"
accepted
jq -e '(has("code") | not) and (has("tools") | not)' <<<"$(sed -n 1p "$t/sent")" >/dev/null
echo 'ok unknown code is left out'

# A forge that predates `tools` or `code` refuses the beat with 422: the beat is sent again without
# `tools`, then without `code`, each refusal is logged once, and the other slots skip them.
printf '9.9.9\n' > "$t/state/beats/claude-version"
: > "$t/sent"; : > "$t/refused"
HEARTBEAT_SENT="$t/sent" HEARTBEAT_REFUSED="$t/refused" HEARTBEAT_CONTRACT="$t/contract.jq" OLD_FORGE=1 \
  PATH="$t/bin:$PATH" JERYU_BASE=https://forge.invalid JERYU_TOKEN_FILE="$t/token" \
  REDTEAM_STATE="$t/state" REDTEAM_RUNNER_ID=fixture/redteam REDTEAM_JOBS=2 \
  "$t/export/ops/pr-redteam/pr-redteam" heartbeat > "$t/out" 2>&1
[[ "$(grep -c . "$t/sent")" == 4 ]] || { echo "expected three tries then one beat: $(cat "$t/sent")" >&2; exit 1; }
[[ "$(grep -c 'heartbeat tools refused (422)' "$t/out")" == 1 && "$(grep -c 'heartbeat code refused (422)' "$t/out")" == 1 ]]
! grep -q 'heartbeat refused for' "$t/out"
jq -se '.[2:] | all((has("code") or has("tools")) | not)' "$t/sent" >/dev/null
echo 'ok an older forge gets the beat without tools, then without code'
echo 'HEARTBEAT CONTRACT PASS'
