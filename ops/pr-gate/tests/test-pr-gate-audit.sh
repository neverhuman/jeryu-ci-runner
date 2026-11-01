#!/usr/bin/env bash
# Exercise pr-gate-audit.sh against a fixture forge, a local bare repository behind the forge's git
# URL, a stand-in governed jankurai and a stand-in verifier: claim, audit in a throwaway clone, submit
# the report from a file (one larger than a single argv string may be), beat /runners, and stay
# harmless when the forge refuses, lacks the routes or asks for a back-off.
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src_bin=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
fx=$(mktemp -d)
trap 'rm -rf -- "$fx"' EXIT
mkdir -p "$fx/install" "$fx/bin" "$fx/home" "$fx/forge" "$fx/git"
for f in pr-gate-audit.sh pr-gate-config.sh pr-gate-backoff.sh pr-gate-state.sh; do cp "$src_bin/$f" "$fx/install/"; done
audit="$fx/install/pr-gate-audit.sh"
printf 'AUDIT-TOKEN-5c1e\n' >"$fx/token"; chmod 0600 "$fx/token"
printf 'PR_GATE_FORGE_URL=https://forge.example.test\nJERYU_TOKEN_FILE=%s\nGATE_RUNNER_IDENTITY=gate-bot\nGATE_RUNNER_OWNERS=acme\n' "$fx/token" >"$fx/pr-gate.env"
HOST=$(hostname -s)

# A repository on the fixture forge: base commit, then a head that changes one file.
git init -q -b main "$fx/work"
git -C "$fx/work" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m base
BASE_SHA=$(git -C "$fx/work" rev-parse HEAD)
printf 'fn main() {}\n' >"$fx/work/main.rs"
git -C "$fx/work" add main.rs
git -C "$fx/work" -c user.name=t -c user.email=t@example.test commit -q -m head
HEAD_SHA=$(git -C "$fx/work" rev-parse HEAD)
git clone -q --bare "$fx/work" "$fx/git/widget.git"
real_git=$(command -v git)

# git: the forge's URL maps to the local bare repository; the credential reaches git only through the
# helper configured in its environment, which names the token FILE, never the token.
cat >"$fx/bin/git" <<SH
#!/usr/bin/env bash
[[ "\$*" != *AUDIT-TOKEN-5c1e* ]] || exit 9
if [[ "\${1:-}" == --version && -e "$fx/git-version" ]]; then cat "$fx/git-version"; exit 0; fi
if [[ " \$* " == *" merge-tree --write-tree "* && -e "$fx/merge-failure" ]]; then exit "\$(cat "$fx/merge-failure")"; fi
if [[ " \$* " == *" merge-tree -h "* && -e "$fx/no-merge-base" ]]; then echo 'usage: git merge-tree --write-tree'; exit 129; fi
if [[ "\${1:-}" == clone ]]; then
  printf '%s\n' "\${GIT_CONFIG_VALUE_1:-}" >>"$fx/git-helper.log"
  args=(); for a in "\$@"; do args+=("\${a/https:\/\/forge.example.test\/git\/acme\//$fx/git/}"); done
  exec "$real_git" "\${args[@]}"
fi
[[ " \$* " != *" checkout "* ]] || printf '%s\n' "\$*" >>"$fx/checkout.log"
# A staged auditor that vanishes after the claim: removed when the head is checked out.
if [[ -e "$fx/vanish-on-checkout" && " \$* " == *" checkout "* ]]; then rm -f -- "\$(cat "$fx/vanish-on-checkout")"; fi
exec "$real_git" "\$@"
SH
# The stand-in auditor: records how it was called and writes a report padded past 128 KiB, unless
# $fx/tool-fails says to write nothing and exit 3.
cat >"$fx/bin/jankurai" <<SH
#!/usr/bin/env bash
[[ "\${1:-}" != --version ]] || { echo 'jankurai 9.9.9'; exit 0; }
printf '%s|%s\n' "\$PWD" "\$*" >>"$fx/jankurai.log"
printf '%s\n' "\$0" >>"$fx/jankurai-bin.log"
# Accept exactly the family's invocations (ops/ci/score.sh, ops/ci/jankurai-gate.sh); the real CLI
# refuses an argument it does not know, so must this stand-in.
sub=\$1; shift; args=("\$@"); i=0
[[ "\$sub" != diff-audit ]] || { tree=\${args[0]}; i=1; }
while ((i < \${#args[@]})); do
  a=\${args[i]}
  case "\$sub \$a" in
    # jankurai 1.7 accepts only the in-tree policy file.
    "audit --policy") [[ "\${args[i+1]:-}" == agent/audit-policy.toml || "\${args[i+1]:-}" == ./agent/audit-policy.toml ]] \
                        || { echo "Error: unsupported audit policy source: --policy must identify ./agent/audit-policy.toml" >&2; exit 1; }
                      i=\$((i + 2));;
    "diff-audit --base-ref"|"diff-audit --json"|"audit --json"|"audit --mode") i=\$((i + 2));;
    "diff-audit --advisory-only"|"diff-audit --skip-proof"|"audit --full"|"audit --no-score-history"|"audit .") i=\$((i + 1));;
    *) echo "error: unexpected argument '\$a' for \$sub" >&2; exit 2;;
  esac
done
set -- "\$sub" "\${args[@]}"
[[ "\${1:-}" == diff-audit ]] || tree=.
cat "\$tree/agent/audit-policy.toml" >"$fx/policy.seen" 2>/dev/null || true
ls "\$tree/agent" >"$fx/agent.seen" 2>/dev/null || true
git -C "\$tree" status --porcelain --untracked-files=no >"$fx/status.seen" 2>/dev/null || true
[[ ! -e "$fx/noisy" ]] || printf 'noisy \033[31mred\033[0m \001tail\n' >&2
[[ ! -e "$fx/tool-fails" ]] || exit 3
out=""; prev=""; for a in "\$@"; do [[ "\$prev" != --json ]] || out=\$a; prev=\$a; done
mkdir -p "\$(dirname "\$out")"
printf '{"score":91,"decision":{"hard_findings":0,"minimum_score":85},"caps_applied":[],"pad":"%s"}\n' \
  "\$(head -c 140000 /dev/zero | tr '\\0' x)" >"\$out"
SH
# The stand-in verifier exports what the real one names after checking the install and its receipt.
JSHA=$(sha256sum "$fx/bin/jankurai" 2>/dev/null | cut -d' ' -f1 || true)
cat >"$fx/install/pr-gate-ensure-jankurai.sh" <<SH
export JERYU_GOVERNED_JANKURAI_BIN="$fx/bin/jankurai" JERYU_JANKURAI_VERSION="jankurai 9.9.9"
export JERYU_JANKURAI_SEMVER=9.9.9 JERYU_JANKURAI_SHA256="\$(sha256sum "$fx/bin/jankurai" | cut -d' ' -f1)"
export JERYU_JANKURAI_RECEIPT_SHA256=$(printf 'e%.0s' {1..64})
printf '%s|%s|%s\n' "\${JERYU_JANKURAI_ALLOW_TEST_RECEIPT-unset}" "\${JERYU_JANKURAI_RECEIPT-unset}" "\${JAIN_RELEASE_CI-unset}" >"$fx/verifier.env"
[[ ! -e "$fx/verifier-refuses" ]] || { echo 'governed jankurai custody mismatch' >&2; exit 1; }
echo 'governed jankurai ok'
SH
# The fixture forge. Claims answer $fx/forge/claim.json once (then nothing), or claim.status; scores
# are kept as score-N.json and answer score.status (default 201); heartbeats are kept in beats.jsonl.
cat >"$fx/bin/curl" <<SH
#!/usr/bin/env bash
[[ "\$*" != *AUDIT-TOKEN-5c1e* ]] || exit 9
url="\${@: -1}" method=GET data="" hdr="" quiet=0 prev=""
for a in "\$@"; do
  case "\$prev" in -X) method=\$a;; --data-binary) data=\$a;; --dump-header) hdr=\$a;; -o) quiet=1;; esac
  prev=\$a
done
printf '%s %s\n' "\$method" "\$url" >>"$fx/curl.log"
answer() { if ((quiet)); then printf '%s' "\$2"; else printf '%s\n%s' "\$1" "\$2"; fi; }
case "\$url" in
  */api/v1/capabilities)
    if [[ -e "$fx/forge/bound" ]]; then answer '{"api_version":1,"jankurai_audit_jobs":{"binding":1,"release":true}}' 200; else answer nope 404; fi;;
  */jankurai-audits/*/release)
    j=\${url%/release}; j=\${j##*/}
    printf '%s %s\n' "\$j" "\$(jq -r .reason "\${data#@}")" >>"$fx/forge/releases.log"
    answer '{}' 200;;
  */jankurai-audits/claim)
    cp "\${data#@}" "$fx/forge/claim-body.json"
    if [[ -e "$fx/forge/claim.status" ]]; then answer nope "\$(cat "$fx/forge/claim.status")"
    elif [[ -e "$fx/forge/claim.json" ]]; then answer "\$(cat "$fx/forge/claim.json")" 200; rm -f "$fx/forge/claim.json"
    else answer '{"leaseSeconds":1800,"tickets":[]}' 200; fi;;
  */jankurai-scores)
    n=0; for f in "$fx"/forge/score-*.json; do [[ -e "\$f" ]] && n=\$((n + 1)); done
    cp "\${data#@}" "$fx/forge/score-\$n.json"
    printf '%s\n' "\${data#@}" >>"$fx/score-bodies.log"
    answer "\$(cat "$fx/forge/score.body" 2>/dev/null || echo '{"score":91}')" "\$(cat "$fx/forge/score.status" 2>/dev/null || echo 201)";;
  */api/v1/merge-queue\?*)
    # The deployed forge also serves a global listing (web.rs: /api/v1/merge-queue -> list_all), but
    # it filters by state and carries no gate_started_at: a repository-scoped read must not use it.
    printf '%s\n' "\$url" >>"$fx/forge/global-queue.log"
    answer '{"code":"invalid_query","message":"this fixture answers only the per-repository listing"}' 422;;
  */api/v1/repos/*/merge-queue\?*)
    if [[ -e "$fx/forge/queue.status" ]]; then
      st=\$(cat "$fx/forge/queue.status")
      [[ "\$st" != timeout ]] || exit 28
      [[ "\$st" != malformed ]] || { answer '{"entries":"not-an-array","page":{"has_more":false}}' 200; exit 0; }
      answer nope "\$st"; exit 0
    fi
    if [[ -e "$fx/forge/queue-strict" ]]; then
      # The route reads limit, per_page and page only (QueuePageQuery::KEYS); strict_query answers
      # any other key with invalid_query at 422, so model exactly that.
      q=\${url#*\?}
      for pair in \${q//&/ }; do
        case "\${pair%%=*}" in
          limit|per_page|page) ;;
          *) printf '%s\n' "\${pair%%=*}" >>"$fx/forge/queue-rejected-keys.log"
             answer '{"code":"invalid_query","message":"unknown query key"}' 422; exit 0;;
        esac
      done
      if [[ -e "$fx/forge/queue-refuses" ]]; then answer '{"code":"invalid_query"}' "\$(cat "$fx/forge/queue-refuses")"; exit 0; fi
      p=\$(sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p' <<<"\$url")
      if [[ -e "$fx/forge/queue-page-\${p:-1}.json" ]]; then answer "\$(cat "$fx/forge/queue-page-\${p:-1}.json")" 200
      else answer '{"entries":[],"total":0,"page":{"has_more":false,"limit":500,"page":0,"total":0}}' 200; fi
      exit 0
    fi
    if [[ -e "$fx/forge/queue-envelope.json" ]]; then answer "\$(cat "$fx/forge/queue-envelope.json")" 200
    elif [[ -e "$fx/forge/queue.json" ]]; then answer "\$(jq -c '{entries: ., page: {has_more: false}}' "$fx/forge/queue.json")" 200
    else answer 'missing queue fixture' 500; fi;;
  */pulls\?state=open*)
    if [[ -e "$fx/forge/pulls.status" ]]; then
      st=\$(cat "$fx/forge/pulls.status")
      [[ "\$st" != timeout ]] || exit 28
      answer nope "\$st"
    elif [[ -e "$fx/forge/listing-overflow" ]]; then
      # A repository whose open pull requests outrun every page this host reads, as a large forge
      # answers it: each page reports another one after it.
      answer '{"items":[],"page":{"has_more":true}}' 200
    elif [[ -e "$fx/forge/pulls-raw.json" ]]; then answer "\$(jq -c '{items: ., page: {has_more: false}}' "$fx/forge/pulls-raw.json")" 200; else
    page=\$(sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p' <<<"\$url")
    if [[ -e "$fx/forge/paged" && "\${page:-1}" == 1 ]]; then answer '{"items":[],"page":{"has_more":true}}' 200; else
    items=\$( { sed 's/.*/{"number":1,"head_sha":"&","labels":["origin:internal"]}/' "$fx/forge/internal-heads" 2>/dev/null
               sed 's/.*/{"number":2,"head_sha":"&","labels":["origin:contributed"]}/' "$fx/forge/contributed-heads" 2>/dev/null; } | jq -cs .)
    [[ ! -e "$fx/forge/summary-labels" ]] || items=\$(jq -c 'map({number, head_sha, summary: {labels}})' <<<"\$items")
    answer "\$(jq -c '{items: ., page: {has_more: false}}' <<<"\$items")" 200; fi; fi;;
  */pulls/[0-9]*)
    # One pull request by number, as the per-number route answers it: the row the listing would carry
    # plus the state and merged flags that route reports, since it is not filtered to open rows.
    n=\${url##*/}
    if [[ -e "$fx/forge/pr-\$n.json" ]]; then answer "\$(cat "$fx/forge/pr-\$n.json")" 200
    elif [[ -e "$fx/forge/pulls-raw.json" ]] \\
      && jq -ce --argjson n "\$n" 'map(select(.number == \$n)) | select(length == 1) | .[0] + {state:"open",merged:false}' \\
        "$fx/forge/pulls-raw.json" >"$fx/forge/pr-answer.json"; then
      answer "\$(cat "$fx/forge/pr-answer.json")" 200
    else answer '{"message":"not found"}' 404; fi;;
  */runners/heartbeat)
    b=\$(cat)
    if [[ -e "$fx/forge/old-heartbeat" ]] && jq -e 'has("tools") or has("code") or has("intervalSeconds")' >/dev/null <<<"\$b"; then answer nope 422
    else printf '%s\n' "\$b" >>"$fx/forge/beats.jsonl"; answer '' 200; fi;;
  *) answer nope 404;;
esac
SH
chmod +x "$fx/bin/git" "$fx/bin/jankurai" "$fx/bin/curl"

run() { cd "$fx" && HOME="$fx/home" PATH="$fx/bin:$PATH" GATE_RUNNER_HOME="$fx/home" PR_GATE_CONFIG="$fx/pr-gate.env" \
  bash "$audit" >"$fx/out" 2>&1; }
must() { local why=$1; shift; "$@" || { printf 'FAIL: %s\n' "$why" >&2; cat "$fx/out" >&2; exit 1; }; }
scores() { local n=0 f; for f in "$fx"/forge/score-*.json; do [[ -e "$f" ]] && n=$((n + 1)); done; echo "$n"; }
internal() { printf '%s\n' "$@" >>"$fx/forge/internal-heads"; }
ticket() { # mode
  internal "$HEAD_SHA"
  printf '{"leaseSeconds":1800,"tickets":[{"owner":"acme","repo":"widget","branch":"feature/x","headSha":"%s","baseSha":"%s","auditMode":"%s"}]}' \
    "$HEAD_SHA" "$BASE_SHA" "$1" >"$fx/forge/claim.json"
}
last_beat() { grep . "$fx/forge/beats.jsonl" | tail -n 1; }

run
must 'an idle pass ends cleanly' grep -q 'no audit work claimed' "$fx/out"
must 'an idle pass submits nothing' test "$(scores)" == 0
must 'an idle pass beats once as the auditor' test "$(last_beat | jq -r '.runnerId + " " + (.labels | join(","))')" == "$HOST/jankurai-audit jankurai-audit"
must 'the beat names the verified auditor' test "$(last_beat | jq -r '.tools[0] | .name + " " + .version')" == "jankurai 9.9.9"
printf 'PASS an idle pass claims nothing, submits nothing and beats once\n'

ticket diff
run
must 'one diff audit is submitted' test "$(scores)" == 1
s="$fx/forge/score-0.json"
must 'the submission names the ticketed head and base' test "$(jq -r '[.branch, .commit_sha, .base_sha, .audit_mode] | join(" ")' "$s")" == "feature/x $HEAD_SHA $BASE_SHA diff"
must 'the submission names the verified auditor' test "$(jq -r '.jankurai_version' "$s")" == "jankurai 9.9.9"
must 'the auditor digest is the binary measured by the verifier' test "$(jq -r '.jankurai_sha256' "$s")" == "$JSHA"
must 'the receipt digest is passed on' test "$(jq -r '.jankurai_receipt_sha256' "$s" | cut -c1-3)" == eee
must 'the runner id is the auditor' test "$(jq -r '.runner_id' "$s")" == "$HOST/jankurai-audit"
must 'the report is the auditor output' test "$(jq -r '.report.score' "$s")" == 91
must 'a report larger than one argv string still goes out' test "$(stat -c %s "$s")" -gt 131072
must 'the diff audit ran against the ticketed base, as jankurai-gate.sh renders it' grep -q "diff-audit .* --base-ref $BASE_SHA --json [^ ]* --advisory-only --skip-proof\$" "$fx/jankurai.log"
must 'the report names the policy it was scored by' test "$(jq -r '.report.jeryu_audit_policy.source' "$s")" == default
must 'a head without a policy gets the default naming the verified version' grep -qx 'required_tool_version = "9.9.9"' "$fx/policy.seen"
must 'the clone was authorized through the helper, by file' grep -q "'gate-bot' '$fx/token'" "$fx/git-helper.log"
must 'the scored beat is the last' test "$(last_beat | jq -r '.last.conclusion + " " + .last.repo')" == "scored acme/widget"
must 'the token never reached argv' test "$(cat "$fx/curl.log" "$fx/jankurai.log" | grep -c AUDIT-TOKEN || true)" == 0
printf 'PASS a diff ticket is audited in a clone and its large report submitted from a file\n'

: >"$fx/jankurai.log"
ticket full
run
must 'a full ticket is submitted' test "$(scores)" == 2
must 'the full audit names its mode' test "$(jq -r .audit_mode "$fx/forge/score-1.json")" == full
must 'the full audit audits the whole tree, as score.sh does' grep -q '| *audit \. --full --mode advisory --policy agent/audit-policy.toml --json' "$fx/jankurai.log"
printf 'PASS a full ticket audits the whole tree\n'

printf '409\n' >"$fx/forge/score.status"
ticket diff
run
must 'a refusal does not fail the pass' grep -q 'report refused (HTTP 409)' "$fx/out"
must 'a refusal is the last conclusion' test "$(last_beat | jq -r '.last.conclusion')" == refused
rm -f "$fx/forge/score.status"
printf 'PASS a refused report is logged and reported, never fatal\n'

touch "$fx/tool-fails"
ticket diff
run
must 'a failed tool still submits, with its exit' test "$(jq -r '[.tool_exit, (.report == null)] | join(" ")' "$fx/forge/score-$(($(scores) - 1)).json")" == "3 true"
must 'a failed tool is reported as such' test "$(last_beat | jq -r '.last.conclusion')" == tool-failed
rm -f "$fx/tool-fails"
printf 'PASS an auditor that writes nothing is submitted as a tool failure\n'

printf '{"leaseSeconds":1800,"tickets":[{"owner":"..","repo":"widget","branch":"main","headSha":"%s","baseSha":"%s","auditMode":"diff"}]}' \
  "$HEAD_SHA" "$BASE_SHA" >"$fx/forge/claim.json"
before=$(scores)
run
must 'a malformed ticket is skipped' grep -q 'skipping a malformed ticket' "$fx/out"
must 'a malformed ticket submits nothing' test "$(scores)" == "$before"
printf 'PASS a malformed ticket is skipped\n'

printf '404\n' >"$fx/forge/claim.status"
run
must 'a forge without the queue is not an error' grep -q 'has no audit queue (HTTP 404)' "$fx/out"
rm -f "$fx/forge/claim.status"
printf 'PASS a forge without the audit routes is a quiet no-op\n'

mkdir -p "$fx/home/cache"
printf '%s 1\n' "$(($(date +%s) + 600))" >"$fx/home/cache/forge-backoff"
: >"$fx/curl.log"
run
must 'a back-off claims nothing' test "$(grep -c 'jankurai-audits/claim' "$fx/curl.log" || true)" == 0
rm -f "$fx/home/cache/forge-backoff"
printf 'PASS the shared back-off holds the claim\n'

mv "$fx/install/pr-gate-ensure-jankurai.sh" "$fx/verifier.off"
: >"$fx/curl.log"
run
must 'no verifier, no claim' test "$(grep -c 'jankurai-audits/claim' "$fx/curl.log" || true)" == 0
must 'it says the verifier is missing' grep -q 'pr-gate-ensure-jankurai.sh is not installed' "$fx/out"
printf 'PASS a host without the verifier audits nothing\n'

mv "$fx/verifier.off" "$fx/install/pr-gate-ensure-jankurai.sh"

# --- what the head may not choose or reach ---------------------------------------------------------
# repo NAME BASE-SETUP HEAD-SETUP: a bare repository on the fixture forge with a base commit and a
# head commit, each made by running the given shell snippet in the work tree; prints "<base> <head>".
repo() {
  local w="$fx/w-$1"
  git init -q -b main "$w"
  ( cd "$w" && eval "$2" ) && git -C "$w" add -A && git -C "$w" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m base
  local b; b=$(git -C "$w" rev-parse HEAD)
  ( cd "$w" && eval "$3" ) && git -C "$w" add -A && git -C "$w" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m head
  git clone -q --bare "$w" "$fx/git/$1.git"
  printf '%s %s\n' "$b" "$(git -C "$w" rev-parse HEAD)"
}
tickets() { # name:base:head ...
  local t out=() n b h
  for t in "$@"; do IFS=: read -r n b h <<<"$t"
    internal "$h"
    out+=("$(printf '{"owner":"acme","repo":"%s","branch":"feature/x","headSha":"%s","baseSha":"%s","auditMode":"diff"}' "$n" "$h" "$b")")
  done
  printf '{"leaseSeconds":1800,"tickets":[%s]}' "$(IFS=,; echo "${out[*]}")" >"$fx/forge/claim.json"
}

read -r b1 h1 < <(repo lowers 'mkdir agent; printf "minimum_score = 90\n" >agent/audit-policy.toml' \
  'printf "minimum_score = 10\n" >agent/audit-policy.toml; echo x >f')
tickets "lowers:$b1:$h1"
run
must 'a head that lowers its own floor is scored by the base policy' grep -qx 'minimum_score = 90' "$fx/policy.seen"
must 'the policy used is named' grep -q "policy: base $b1" "$fx/out"
printf 'PASS the base commit, not the head, supplies the policy\n'

read -r b2 h2 < <(repo nopolicy 'echo a >a' 'mkdir agent; printf "minimum_score = 1\n" >agent/audit-policy.toml')
tickets "nopolicy:$b2:$h2"
run
must 'a base without a policy gets the default, not the head s' grep -qx 'minimum_score = 85' "$fx/policy.seen"
must 'the default names the verified version' grep -qx 'required_tool_version = "9.9.9"' "$fx/policy.seen"
must 'the default excludes nothing' test "$(grep -c excluded "$fx/policy.seen" || true)" == 0
printf 'PASS a base without a policy gets the default floor\n'

mkdir -p "$fx/outside"; printf 'SECRET-HOST-FILE\n' >"$fx/outside/secret"
read -r b3 h3 < <(repo agentfile 'echo a >a' 'printf "not a dir\n" >agent')
read -r b4 h4 < <(repo plantnew 'echo a >a' "mkdir agent; ln -s '$fx/outside/created-by-head' agent/audit-policy.toml")
read -r b5 h5 < <(repo plantold 'echo a >a' "mkdir agent; ln -s '$fx/outside/secret' agent/audit-policy.toml; ln -s '$fx/outside' .jankurai")
before=$(scores)
tickets "agentfile:$b3:$h3" "plantnew:$b4:$h4" "plantold:$b5:$h5"
printf '3\n' >"$fx/maxjobs"
HOME="$fx/home" PATH="$fx/bin:$PATH" GATE_RUNNER_HOME="$fx/home" PR_GATE_CONFIG="$fx/pr-gate.env" PR_GATE_AUDIT_MAX=3 \
  bash "$audit" >"$fx/out" 2>&1 || { cat "$fx/out" >&2; printf 'FAIL: a hostile head aborted the pass\n' >&2; exit 1; }
must 'all three hostile heads were audited and submitted' test "$(scores)" == "$((before + 3))"
must 'an agent file did not stop the pass' grep -q "acme/agentfile@$h3 scored" "$fx/out"
must 'a planted link created nothing outside the clone' test ! -e "$fx/outside/created-by-head"
must 'a planted link never handed the auditor a host file' test "$(grep -c SECRET-HOST-FILE "$fx/policy.seen" "$fx"/forge/score-*.json 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')" == 0
must 'nothing was written through a planted .jankurai' test "$(ls "$fx/outside")" == secret
printf 'PASS hostile trees (agent as a file, planted links) are made safe and never stop the pass\n'

printf '200\n' >"$fx/forge/score.status"
tickets "lowers:$b1:$h1"
run
must 'a 200 from the ingest is a recorded score' test "$(last_beat | jq -r '.last.conclusion')" == scored
rm -f "$fx/forge/score.status"
printf 'PASS any 2xx from the ingest counts as recorded\n'

touch "$fx/forge/old-heartbeat"
run
must 'an older forge still gets a beat' test "$(last_beat | jq -r '[.runnerId, has("tools"), has("intervalSeconds")] | join(" ")')" == "$HOST/jankurai-audit false false"
rm -f "$fx/forge/old-heartbeat"
printf 'PASS a forge that refuses the newer heartbeat fields still sees the auditor\n'

printf 'JERYU_JANKURAI_ALLOW_TEST_RECEIPT=1\nJERYU_JANKURAI_RECEIPT=/tmp/x.json\n' >>"$fx/pr-gate.env"
run
must 'no widening switch reaches the verifier' test "$(cat "$fx/verifier.env")" == "unset|unset|unset"
touch "$fx/verifier-refuses"
: >"$fx/curl.log"
run
must 'a refusing verifier is named' grep -q 'does not verify on this host: governed jankurai custody mismatch' "$fx/out"
must 'a refusing verifier claims nothing' test "$(grep -c 'jankurai-audits/claim' "$fx/curl.log" || true)" == 0
rm -f "$fx/verifier-refuses"
printf 'PASS the verifier runs with no widening switches, and a refusal audits nothing\n'

# --- only reviewed code is checked out ---------------------------------------------------------------
read -r b6 h6 < <(repo contrib 'echo a >a' 'echo b >b')
printf '%s\n' "$h6" >>"$fx/forge/contributed-heads"
printf '{"leaseSeconds":1800,"tickets":[{"owner":"acme","repo":"contrib","branch":"fork/x","headSha":"%s","baseSha":"%s","auditMode":"diff"}]}' "$h6" "$b6" >"$fx/forge/claim.json"
: >"$fx/git-helper.log"; before=$(scores)
run
must 'a contribution is not audited here' grep -q "not auditing acme/contrib@$h6 here: a contribution (origin:contributed)" "$fx/out"
must 'a contribution is never cloned' test ! -s "$fx/git-helper.log"
must 'a contribution submits nothing' test "$(scores)" == "$before"
read -r b7 h7 < <(repo orphanpr 'echo c >c' 'echo d >d')
printf '{"leaseSeconds":1800,"tickets":[{"owner":"acme","repo":"orphanpr","branch":"feature/y","headSha":"%s","baseSha":"%s","auditMode":"diff"}]}' "$h7" "$b7" >"$fx/forge/claim.json"
run
must 'a head no open pull request holds is not audited' grep -q 'no open pull request holds this head' "$fx/out"
printf '503\n' >"$fx/forge/pulls.status"
printf '{"leaseSeconds":1800,"tickets":[{"owner":"acme","repo":"orphanpr","branch":"feature/y","headSha":"%s","baseSha":"%s","auditMode":"diff"}]}' "$h7" "$b7" >"$fx/forge/claim.json"
run
must 'a forge that cannot say is refused' grep -q 'the forge answered 503 listing its pull requests' "$fx/out"
printf '{"leaseSeconds":1800,"tickets":[{"owner":"acme","repo":"orphanpr","branch":"main","headSha":"%s","baseSha":"%s","auditMode":"diff"}]}' "$h7" "$b7" >"$fx/forge/claim.json"
run
must 'main is reviewed code and needs no pull request' grep -q "acme/orphanpr@$h7 scored" "$fx/out"
rm -f "$fx/forge/pulls.status"
# A head several open pull requests hold is only as reviewed as the least reviewed of them: the
# listing is read past the first match, so a contributed holder refuses the head even when an
# internal row for the same head comes first.
read -r b9 h9 < <(repo shared 'echo e >e' 'echo f >f')
internal "$h9"; printf '%s\n' "$h9" >>"$fx/forge/contributed-heads"
printf '{"leaseSeconds":1800,"tickets":[{"owner":"acme","repo":"shared","branch":"feature/z","headSha":"%s","baseSha":"%s","auditMode":"diff"}]}' "$h9" "$b9" >"$fx/forge/claim.json"
: >"$fx/git-helper.log"; before=$(scores)
run
must 'a head an internal and a contributed row both hold is a contribution' \
  grep -q "not auditing acme/shared@$h9 here: a contribution (origin:contributed)" "$fx/out"
must 'a head with a contributed holder is never cloned' test ! -s "$fx/git-helper.log"
must 'a head with a contributed holder submits nothing' test "$(scores)" == "$before"
grep -v "^$h9\$" "$fx/forge/contributed-heads" >"$fx/forge/heads.tmp"; mv "$fx/forge/heads.tmp" "$fx/forge/contributed-heads"
printf '{"leaseSeconds":1800,"tickets":[{"owner":"acme","repo":"shared","branch":"feature/z","headSha":"%s","baseSha":"%s","auditMode":"diff"}]}' "$h9" "$b9" >"$fx/forge/claim.json"
run
must 'the same head with only internal holders is audited' grep -q "acme/shared@$h9 scored" "$fx/out"
# A listing this host cannot read to its end cannot say who holds the head, and says so.
touch "$fx/forge/listing-overflow"; before=$(scores); : >"$fx/git-helper.log"
printf '{"leaseSeconds":1800,"tickets":[{"owner":"acme","repo":"shared","branch":"feature/z","headSha":"%s","baseSha":"%s","auditMode":"diff"}]}' "$h9" "$b9" >"$fx/forge/claim.json"
run
must 'an unreadable listing refuses the head with its reason' \
  grep -q 'lists more open pull requests than this host can page' "$fx/out"
must 'an unreadable listing clones nothing' test ! -s "$fx/git-helper.log"
must 'an unreadable listing submits nothing' test "$(scores)" == "$before"
rm -f -- "$fx/forge/listing-overflow"
printf 'PASS only main and internal pull request heads are checked out; contributions and unknowns are not\n'

printf '{"leaseSeconds":1800,"tickets":[{"owner":"acme","repo":"orphanpr","branch":"main","headSha":"%s","baseSha":"","auditMode":"full"}]}' "$h7" >"$fx/forge/claim.json"
run
must 'a full job with no base is audited' grep -q "acme/orphanpr@$h7 scored .*full audit" "$fx/out"
must 'its base is passed on as given' test "$(jq -r '.base_sha' "$fx/forge/score-$(($(scores) - 1)).json")" == ""
printf 'PASS a full job with no commit base is audited, not dropped\n'

# --- scope, main, metadata, and what the auditor sees ------------------------------------------------
printf '{"leaseSeconds":1800,"tickets":[{"owner":"other","repo":"widget","branch":"main","headSha":"%s","baseSha":"%s","auditMode":"diff"}]}' "$HEAD_SHA" "$BASE_SHA" >"$fx/forge/claim.json"
: >"$fx/git-helper.log"
run
must 'another owner is not served' grep -q 'other is not an owner this host serves' "$fx/out"
must 'another owner is never cloned' test ! -s "$fx/git-helper.log"

w="$fx/w-side"; git init -q -b main "$w"; echo a >"$w/a"; git -C "$w" add -A; git -C "$w" -c user.name=t -c user.email=t@example.test commit -qm base
sb=$(git -C "$w" rev-parse HEAD); git -C "$w" checkout -q -b side; echo s >"$w/s"; git -C "$w" add -A
git -C "$w" -c user.name=t -c user.email=t@example.test commit -qm side; sh=$(git -C "$w" rev-parse HEAD); git clone -q --bare "$w" "$fx/git/side.git"
printf '{"leaseSeconds":1800,"tickets":[{"owner":"acme","repo":"side","branch":"main","headSha":"%s","baseSha":"%s","auditMode":"diff"}]}' "$sh" "$sb" >"$fx/forge/claim.json"
: >"$fx/jankurai.log"
run
must 'a ticket that says main for a head not on main is refused' grep -q 'the ticket says main, but the head is not on main' "$fx/out"
must 'and nothing is audited' test ! -s "$fx/jankurai.log"
printf 'PASS only this host s owners, and main only when the head is on main\n'

read -r b8 h8 < <(repo zones 'mkdir agent; printf "minimum_score = 88\n" >agent/audit-policy.toml; ln -s ../../../etc agent/escape' \
  'printf "[[zone]]\npath = \"src\"\n" >agent/generated-zones.toml; echo y >y; ln -sf /etc/hostname host-link')
tickets "zones:$b8:$h8"
touch "$fx/noisy"
run
must 'the head s own zones never reach the auditor' test "$(grep -c generated-zones "$fx/agent.seen" || true)" == 0
must 'the base policy is used' grep -qx 'minimum_score = 88' "$fx/policy.seen"
must 'the auditor sees none of the hardening as a change' test ! -s "$fx/status.seen"
must 'no control character reaches the journal' test "$(LC_ALL=C grep -c $'[\x01\x1b]' "$fx/out" || true)" == 0
rm -f "$fx/noisy"
printf 'PASS a diff job audits with the base metadata, and the hardening is invisible to the diff\n'

touch "$fx/forge/summary-labels" "$fx/forge/paged"
tickets "lowers:$b1:$h1"
run
must 'a head on page 2 with summary labels is admitted' grep -q "acme/lowers@$h1 scored" "$fx/out"
rm -f "$fx/forge/summary-labels" "$fx/forge/paged"
printf 'PASS labels under .summary and heads past the first page are found\n'

set +e; HOME="$fx/home" PATH="$fx/bin:$PATH" GATE_RUNNER_HOME="$fx/home" PR_GATE_CONFIG="$fx/pr-gate.env" PR_GATE_AUDIT_MAX=8 PR_GATE_AUDIT_TIMEOUT=5000 bash "$audit" >"$fx/out" 2>&1; rc=$?; set -e
must 'a pass that cannot fit the unit is refused' test "$rc" == 2
must 'and says why' grep -q "exceeds the unit's 10h limit" "$fx/out"
printf 'PASS jobs x timeout must fit the unit\n'

# --- the metadata source must itself be on main --------------------------------------------------------
# A PR based on an author-pushed branch X: X's policy (floor 0) must not score it; main's (floor 92) does.
w="$fx/w-stack"; git init -q -b main "$w"; mkdir -p "$w/agent"; printf 'minimum_score = 92\n' >"$w/agent/audit-policy.toml"
git -C "$w" add -A; git -C "$w" -c user.name=t -c user.email=t@example.test commit -qm main
git -C "$w" checkout -q -b x; printf 'minimum_score = 0\n' >"$w/agent/audit-policy.toml"; git -C "$w" -c user.name=t -c user.email=t@example.test commit -qam x
xb=$(git -C "$w" rev-parse HEAD); git -C "$w" checkout -q -b y; echo y >"$w/y"; git -C "$w" add -A
git -C "$w" -c user.name=t -c user.email=t@example.test commit -qm y; yh=$(git -C "$w" rev-parse HEAD); git clone -q --bare "$w" "$fx/git/stack.git"
internal "$yh"
printf '{"leaseSeconds":1800,"tickets":[{"owner":"acme","repo":"stack","branch":"y","headSha":"%s","baseSha":"%s","auditMode":"diff"}]}' "$yh" "$xb" >"$fx/forge/claim.json"
run
must 'a base main does not reach never supplies the policy' grep -qx 'minimum_score = 92' "$fx/policy.seen"
must 'and the report says so' grep -q 'policy: main .*(the base is not on main)' "$fx/out"
printf '{"leaseSeconds":1800,"tickets":[{"owner":"acme","repo":"stack","branch":"y","headSha":"%s","baseSha":"","auditMode":"full"}]}' "$yh" >"$fx/forge/claim.json"
run
must 'a full job off main is scored by main s metadata, not the head s' grep -qx 'minimum_score = 92' "$fx/policy.seen"
printf 'PASS the metadata source is always a commit main reaches\n'

tickets "lowers:$b1:$h1" "nopolicy:$b2:$h2"
run
must 'more tickets than asked are cut to MAX' grep -q 'the forge handed out 2 jobs for 1; auditing 1' "$fx/out"
must 'the token config is not beside the clone' test "$(find "$fx/home/audit-work" -name 'curl-auth*' 2>/dev/null | wc -l)" == 0
touch "$fx/verifier-refuses"
run
must 'a refusing verifier still tells /runners why' test "$(last_beat | jq -r '.last.reason')" == "the governed jankurai does not verify on this host: governed jankurai custody mismatch"
rm -f "$fx/verifier-refuses"
printf 'PASS the pass budget is enforced, the token sits apart, and a refusal is visible on /runners\n'

# --- the bound contract (ADR 0011): job-assigned auditors, staged by digest -----------------------------
SIGNER=$(printf 'c%.0s' {1..64}) TARGET=x86_64-unknown-linux-gnu MREV=$(printf 'a%.0s' {1..40}) MSHA=$(printf 'b%.0s' {1..64})
# stage: put the stand-in auditor under <tools>/jankurai/<sha>/ with an installation receipt; prints its digest.
stage() {
  local sha d
  sha=$(sha256sum <"$fx/bin/jankurai" | cut -c1-64); d="$fx/tools/jankurai/$sha"
  mkdir -p "$d/bin"; cp "$fx/bin/jankurai" "$d/bin/jankurai"; chmod 0755 "$d/bin/jankurai"
  jq -n --arg sha "$sha" --arg signer "$SIGNER" --arg target "$TARGET" '{schema: "jeryu.jankurai-installation/v3",
    binary: {sha256: $sha, version_output: "jankurai 9.9.9"}, build: {target_triple: $target},
    signature: {verified: true, signer_sha256: $signer}, test_mode: false, conclusion: "success",
    governance: {status: "governed", manifest_commit: "0000000000000000000000000000000000000000"}}' >"$d/receipt.json"
  printf '%s\n' "$sha"
}
# bticket NAME BASE HEAD METADATA POLICY-SHA [ORIGIN PURPOSE AUDITOR-SHA VERSION BRANCH MODE]: one bound job.
bticket() {
  jq -n --arg repo "$1" --arg base "$2" --arg head "$3" --arg mc "$4" --arg psha "$5" --arg origin "${6:-internal}" \
    --arg purpose "${7:-proof}" --arg sha "${8:-$SSHA}" --arg ver "${9:-9.9.9}" --arg branch "${10:-feature/x}" \
    --arg mode "${11:-diff}" --arg signer "$SIGNER" --arg target "$TARGET" --arg mrev "$MREV" --arg msha "$MSHA" '
    {leaseSeconds: 1800, tickets: [{job_id: ("job-" + ($head | .[0:8])), owner: "acme", repo: $repo, branch: $branch,
      head_sha: $head, base_sha: $base, audit_mode: $mode, purpose: $purpose, origin: $origin,
      metadata_commit: $mc, policy_sha256: $psha,
      auditor: {manifest_revision: $mrev, manifest_sha256: $msha, version: $ver, target: $target,
                binary_sha256: $sha, signing_identity: $signer}}]}' >"$fx/forge/claim.json"
}
polsha() { git -C "$fx/git/$1.git" show "$2:agent/audit-policy.toml" | sha256sum | cut -c1-64; }
DEFAULT_SHA=$(printf '%s\n' 'schema_version = "1.0.0"' 'workspace = "unconfigured"' 'minimum_score = 85' \
  'hard_findings_allowed = 0' 'required_tool = "jankurai"' | sha256sum | cut -c1-64)
released() { tail -n 1 "$fx/forge/releases.log" 2>/dev/null; }
last_score() { jq -c . "$fx/forge/score-$(($(scores) - 1)).json"; }

touch "$fx/forge/bound"
printf 'PR_GATE_AUDIT_TOOLS=%s\n' "$fx/tools" >>"$fx/pr-gate.env"
# The bound contract needs no release-specific verifier: prove it by taking that one away.
mv "$fx/install/pr-gate-ensure-jankurai.sh" "$fx/verifier.bound-off"
SSHA=$(stage)
run
must 'a bound claim offers the staged auditor by digest' test "$(jq -c '.capabilities' "$fx/forge/claim-body.json")" == "{\"jankurai\":[\"$SSHA\"],\"sandbox\":false}"
must 'the beat lists the staged auditor' test "$(last_beat | jq -r '.tools[0].sha256')" == "$SSHA"
printf 'PASS a bound claim offers exactly the staged, receipt-verified auditors\n'

: >"$fx/jankurai-bin.log"
bticket lowers "$b1" "$h1" "$b1" "$(polsha lowers "$b1")"
run
s=$(last_score)
must 'a bound job is submitted with its binding' test "$(jq -r '[.job_id, .metadata_commit, .auditor.binary_sha256, .jankurai_sha256, .jankurai_version] | join(" ")' <<<"$s")" == "job-${h1:0:8} $b1 $SSHA $SSHA jankurai 9.9.9"
must 'the policy digest is echoed' test "$(jq -r .policy_sha256 <<<"$s")" == "$(polsha lowers "$b1")"
must 'the receipt digest is the staged receipt s' test "$(jq -r .receipt_sha256 <<<"$s")" == "$(sha256sum <"$fx/tools/jankurai/$SSHA/receipt.json" | cut -c1-64)"
must 'the assigned, staged binary ran' test "$(tail -n 1 "$fx/jankurai-bin.log")" == "$fx/tools/jankurai/$SSHA/bin/jankurai"
must 'the job s metadata commit supplied the policy' grep -qx 'minimum_score = 90' "$fx/policy.seen"
must 'the report carries no runner-side policy note' test "$(jq -r '.report | has("jeryu_audit_policy")' <<<"$s")" == false
must 'the publishing state was reported' grep -q '"state":"publishing"' "$fx/forge/beats.jsonl"
must 'a bound job is scored' test "$(last_beat | jq -r .last.conclusion)" == scored
printf 'PASS a bound job runs its assigned auditor on its metadata and echoes the binding\n'

before=$(scores)
bticket nopolicy "$b2" "$h2" "$b2" "$DEFAULT_SHA"
run
must 'a commit without a policy is scored by the fixed default' test "$(scores)" == "$((before + 1))"
must 'the default names no auditor version' test "$(grep -c required_tool_version "$fx/policy.seen" || true)" == 0
printf 'PASS the fixed default policy hashes to the bound digest\n'

bad() { # why reason [git-helper must stay empty]
  local why=$1 reason=$2 before; before=$(scores); : >"$fx/git-helper.log"
  run
  must "$why: handed back as $reason" test "$(released | cut -d' ' -f2)" == "$reason"
  must "$why: nothing submitted" test "$(scores)" == "$before"
  must "$why: reported released" test "$(last_beat | jq -r .last.conclusion)" == released
  [[ "${3:-}" != uncloned ]] || must "$why: never cloned" test ! -s "$fx/git-helper.log"
}
bticket lowers "$b1" "$h1" "$b1" "$(printf '0%.0s' {1..64})"; bad 'a policy that does not hash to the job' policy-mismatch
bticket lowers "$b1" "$h1" "$b1" "$(polsha lowers "$b1")" internal proof "$(printf 'd%.0s' {1..64})"
bad 'an auditor this host has not staged' staged-digest-missing uncloned
bticket lowers "$b1" "$h1" "$b1" "$(polsha lowers "$b1")" internal proof "$SSHA" 9.9.8
bad 'a staged auditor whose receipt names another version' verifier-mismatch uncloned
bticket stack "$xb" "$yh" "$xb" "$(polsha stack "$xb")" internal proof "$SSHA" 9.9.9 y
bad 'a metadata commit main does not reach' not-on-main
printf '%s\n' "$fx/tools/jankurai/$SSHA/bin/jankurai" >"$fx/vanish-on-checkout"
bticket lowers "$b1" "$h1" "$b1" "$(polsha lowers "$b1")"; bad 'an auditor that vanished after the claim' tool-gone
rm -f "$fx/vanish-on-checkout"; SSHA=$(stage)
printf 'PASS a bound job its host cannot honestly run is handed back with its reason, never scored\n'

: >"$fx/git-helper.log"
bticket lowers "$b1" "$h1" "$b1" "$(polsha lowers "$b1")" contributed
run
must 'a contribution is handed back' test "$(released | cut -d' ' -f2)" == contributed
must 'a contribution is never cloned' test ! -s "$fx/git-helper.log"
jq -n '{leaseSeconds: 1800, tickets: [{job_id: "job-bad", owner: "acme", repo: "lowers", branch: "feature/x",
  head_sha: "'"$h1"'", base_sha: "'"$b1"'", audit_mode: "diff", purpose: "proof", origin: "internal"}]}' >"$fx/forge/claim.json"
run
must 'a ticket with no auditor binding is handed back as malformed' test "$(released)" == 'job-bad malformed-ticket'
printf 'PASS contributions and malformed bound tickets are handed back without a clone\n'

# The site's sandbox adapter owns isolation; this fixture proves the production handoff contract
# and runs the same assigned auditor on the prepared tree, without network or a live forge.
cat >"$fx/bin/audit-sandbox" <<SH
#!/usr/bin/env bash
set -eu
[[ -z "\${JERYU_TOKEN_FILE:-}\${GATE_RUNNER_IDENTITY:-}\${HOME:-}\${GIT_CONFIG_VALUE_1:-}" ]]
[[ ! -e /proc/\$\$/fd/9 ]]
root=\$1; repo=\$2; shift 2
[[ "\$repo" == src && "\$PWD" == "\$root/src" ]]
[[ ! -e "\$root/token" && ! -e "\$root/audit-auth" ]]
[[ "\$(find "\$root" -type f -exec grep -l AUDIT-TOKEN-5c1e {} + | wc -l)" == 0 ]]
printf '%s\n' "\$root" >"$fx/sandbox.seen"
[[ ! -e "$fx/sandbox-fails" ]] || exit 7
exec "\$@"
SH
chmod +x "$fx/bin/audit-sandbox"
printf 'PR_GATE_SANDBOX_COMMAND=%s\nPR_GATE_SANDBOX_PATH=%s\n' "$fx/bin/audit-sandbox" "$fx/bin:/usr/bin:/bin" >>"$fx/pr-gate.env"
before=$(scores)
bticket lowers "$b1" "$h1" "$b1" "$(polsha lowers "$b1")" contributed proof "$SSHA" 9.9.9 contrib/gh-42
run
must 'a configured sandbox is advertised with the staged digest' test "$(jq -c .capabilities "$fx/forge/claim-body.json")" == "{\"jankurai\":[\"$SSHA\"],\"sandbox\":true}"
must 'a contributed ticket is audited and submitted' test "$(scores)" == "$((before + 1))"
must 'the sandbox command received the clean environment and tree' test -s "$fx/sandbox.seen"
must 'the contribution proof binds the exact head and job' test "$(last_score | jq -r '[.branch,.head_sha,.job_id,.report.score,.tool_exit] | join(" ")')" == "contrib/gh-42 $h1 job-${h1:0:8} 91 0"
must 'the sandbox runs the copied assigned auditor' test "$(tail -n 1 "$fx/jankurai-bin.log")" == "$(cat "$fx/sandbox.seen")/auditor"
must 'the contribution still uses the trusted policy' grep -qx 'minimum_score = 90' "$fx/policy.seen"
# Failure cannot fall through to a host execution or reuse the preceding report.
touch "$fx/sandbox-fails"
bticket lowers "$b1" "$h1" "$b1" "$(polsha lowers "$b1")" contributed
run
must 'sandbox failure submits no score evidence' test "$(last_score | jq -c '[.tool_exit,.report]')" == '[7,null]'
must 'sandbox failure is visible' test "$(last_beat | jq -r .last.conclusion)" == tool-failed
rm -f "$fx/sandbox-fails"
# No PR row and no discovered clone: the bound forge ticket alone admits a personal-agent head.
: >"$fx/curl.log"
bticket orphanpr "$b7" "$h7" "$b7" "$DEFAULT_SHA" internal proof "$SSHA" 9.9.9 personal/agent
run
must 'a personal-agent head uses the exact ticket' test "$(last_score | jq -r '[.branch,.head_sha,.job_id,.report.score] | join(" ")')" == "personal/agent $h7 job-${h7:0:8} 91"
must 'bound admission does not consult PR discovery' test "$(grep -c '/pulls?' "$fx/curl.log" || true)" == 0
bticket lowers "$b1" "$h1" "$b1" "$(polsha lowers "$b1")" contributed
jq '.tickets[0].owner = "outside"' "$fx/forge/claim.json" >"$fx/forge/claim.tmp"
mv "$fx/forge/claim.tmp" "$fx/forge/claim.json"
: >"$fx/git-helper.log"; before=$(scores)
run
must 'sandbox capability does not widen repository scope' test "$(released | cut -d' ' -f2)" == not-served-by-this-host
must 'an outside contribution is not cloned or scored' test ! -s "$fx/git-helper.log"
must 'an outside contribution produces no evidence' test "$(scores)" == "$before"
printf 'PASS bound contributed and personal-agent heads get exact-head proof; sandbox failures stay failures\n'

printf '202\n' >"$fx/forge/score.status"
printf '{"job_id":"j","recorded_as":"qualification","qualification":"q-1"}\n' >"$fx/forge/score.body"
bticket lowers "$b1" "$h1" "$b1" "$(polsha lowers "$b1")" internal qualification
run
must 'a qualification run is reported as qualified' test "$(last_beat | jq -r .last.conclusion)" == qualified
must 'and names its record' grep -q 'recorded as qualification q-1 for jankurai 9.9.9' "$fx/out"
printf '422\n' >"$fx/forge/score.status"
printf '{"code":"auditor_mismatch","field":"policy_sha256"}\n' >"$fx/forge/score.body"
bticket lowers "$b1" "$h1" "$b1" "$(polsha lowers "$b1")"
run
must 'a refused binding is a rejected publication' test "$(last_beat | jq -r .last.conclusion)" == rejected-publication
must 'with the forge s reason' test "$(last_beat | jq -r .last.reason)" == 'the forge refused the report (HTTP 422; auditor_mismatch: policy_sha256)'
rm -f "$fx/forge/score.status" "$fx/forge/score.body"
printf 'PASS qualification and rejected publications are reported as such\n'

rm -rf "$fx/tools/jankurai"
run
must 'a bound host with nothing staged claims nothing' test "$(last_beat | jq -r .last.reason)" == "no staged jankurai under $fx/tools/jankurai verifies on its receipt"
rm -f "$fx/forge/bound"; mv "$fx/verifier.bound-off" "$fx/install/pr-gate-ensure-jankurai.sh"
printf 'PASS a bound host with no staged auditor says so on /runners\n'

# --- merge-queue tickets: a queue commit exists only under refs/queue --------------------------------
# The synthetic queue commits are pushed to the bare repository's refs/queue/main/N and no branch holds
# them, so only a fetch of that exact ref can check them out; no pull request has their sha as its head.
qw="$fx/w-queue"
git init -q -b main "$qw"
qgit() { git -C "$qw" -c user.name=t -c user.email=t@example.test "$@"; }
qgit commit -q --allow-empty -m base
QBASE=$(git -C "$qw" rev-parse HEAD)
git clone -q --bare "$qw" "$fx/git/qrepo.git"
qcommit() { # file -> sha of a commit on QBASE (or $2) that no branch holds
  qgit checkout -q --detach "${2:-$QBASE}"; echo "$1" >"$qw/$1"; qgit add "$1"; qgit commit -q -m "$1"; git -C "$qw" rev-parse HEAD
}
# Model the protected forge's real replay: two independent PRs fork before main advances,
# then build_on replays the first onto main and the second onto the first queue commit.
QFORK=$QBASE
QSRC1=$(qcommit pr1 "$QFORK"); QSRC2=$(qcommit pr2 "$QFORK")
QBASE=$(qcommit main-update "$QFORK")
git -C "$fx/git/qrepo.git" fetch -q "$qw" "$QBASE:refs/heads/main"
qreplay() { qgit checkout -q --detach "$1"; qgit cherry-pick "$2" >&2; git -C "$qw" rev-parse HEAD; }
QQ1=$(qreplay "$QBASE" "$QSRC1"); QQ2=$(qreplay "$QQ1" "$QSRC2")
git -C "$qw" push -q "$fx/git/qrepo.git" "$QSRC1:refs/pull/1/head" "$QSRC2:refs/pull/2/head"
for sha in "$QSRC1" "$QQ1" "$QSRC2" "$QQ2"; do git -C "$qw" push -q "$fx/git/qrepo.git" "$sha:refs/qtmp/$sha"; done
git -C "$fx/git/qrepo.git" update-ref refs/queue/main/1 "$QQ1"
git -C "$fx/git/qrepo.git" update-ref refs/queue/main/2 "$QQ2"
for sha in "$QSRC1" "$QQ1" "$QSRC2" "$QQ2"; do git -C "$fx/git/qrepo.git" update-ref -d "refs/qtmp/$sha"; done
must 'the fixture queue commit is on no branch' test -z "$(git -C "$fx/git/qrepo.git" branch --contains "$QQ2")"
qlive() { # writes the live queue and open pull requests the forge reports; $1 = labels of PR 1
  jq -n --arg b "$QBASE" --arg s1 "$QSRC1" --arg q1 "$QQ1" --arg s2 "$QSRC2" --arg q2 "$QQ2" '[
    {repo:"acme/qrepo",base:"main",number:1,pr_head_sha:$s1,base_sha:$b,queue_ref:"refs/queue/main/1",queue_sha:$q1,state:"building"},
    {repo:"acme/qrepo",base:"main",number:2,pr_head_sha:$s2,base_sha:$q1,after:1,queue_ref:"refs/queue/main/2",queue_sha:$q2,state:"building"}]' >"$fx/forge/queue.json"
  jq -n --arg s1 "$QSRC1" --arg s2 "$QSRC2" --argjson l1 "${1:-[\"origin:internal\"]}" \
    '[{number:1,head_sha:$s1,labels:$l1},{number:2,head_sha:$s2,labels:["origin:internal"]}]' >"$fx/forge/pulls-raw.json"
}
qticket() { # ref sha base
  printf '{"leaseSeconds":1800,"tickets":[{"owner":"acme","repo":"qrepo","branch":"%s","headSha":"%s","baseSha":"%s","auditMode":"diff"}]}' \
    "$1" "$2" "$3" >"$fx/forge/claim.json"
}
qlive
before=$(scores)
qticket refs/queue/main/2 "$QQ2" "$QBASE"
run
must 'a stacked queue ticket is admitted and audited' grep -q "acme/qrepo@$QQ2 scored" "$fx/out"
must 'it is submitted under its exact queue ref and sha' test "$(jq -r '[.branch, .commit_sha] | join(" ")' "$fx/forge/score-$before.json")" == "refs/queue/main/2 $QQ2"
must 'the audited tree is the queue commit' grep -q 'pr2' <(git -C "$fx/git/qrepo.git" ls-tree --name-only "$QQ2")
printf 'PASS a queue commit reachable only through refs/queue is fetched, audited and submitted\n'

# Recorded deployed build_on response: preserve its envelope and replay-parent
# mapping while substituting only fixture object identities and PR numbers.
recorded="$test_dir/fixtures/merge-queue-60da213.json"
must 'the deployed stacked base is its preceding queue SHA, not the main tip' jq -e '
  .page.has_more == false and .page.limit == 500 and .page.page == 1 and .total == 2
  and ([.entries[] | select(.number == 29)][0] as $first
    | [.entries[] | select(.number == 22)][0] as $second
    | $first.state == "building" and $second.state == "building"
      and $second.after == $first.number and $second.base_sha == $first.queue_sha
      and $second.base_sha != $first.base_sha
      and $first.queue_ref == "refs/queue/main/29" and $second.queue_ref == "refs/queue/main/22")' "$recorded"
jq --arg b "$QBASE" --arg s1 "$QSRC1" --arg q1 "$QQ1" --arg s2 "$QSRC2" --arg q2 "$QQ2" '
  .entries |= map(if .number == 29 then
    .number=1 | .pr_head_sha=$s1 | .base_sha=$b | .queue_sha=$q1 | .queue_ref="refs/queue/main/1"
    else .number=2 | .after=1 | .pr_head_sha=$s2 | .base_sha=$q1 | .queue_sha=$q2 | .queue_ref="refs/queue/main/2" end
    | .repo="acme/qrepo")' "$recorded" >"$fx/forge/queue-envelope.json"
qticket refs/queue/main/2 "$QQ2" "$QBASE"; before=$(scores); run
must 'the recorded deployed response admits and audits its complete replay stack' test "$(scores)" == "$((before + 1))"
must 'the production listing route consumes the recorded envelope' grep -q 'GET https://forge.example.test/api/v1/repos/acme%2Fqrepo/merge-queue?per_page=500&page=1' "$fx/curl.log"
rm "$fx/forge/queue-envelope.json"
printf 'PASS the deployed forge envelope and build_on replay-parent contract are pinned\n'

# --- the production route, as the deployed forge serves it ------------------------------------------
# `/api/v1/repos/:id/merge-queue` (web.rs:1396 -> merge_queue::list_repo) accepts the paging keys
# `limit`, `per_page` and `page` only (QueuePageQuery::KEYS) and refuses any other key with
# `invalid_query` at 422; the global `/api/v1/merge-queue` listing is a different contract. Serve the
# recorded envelope's own entry schema one entry per page, so the whole live stack is only visible to
# a consumer that reads this route and follows its `page.has_more`.
qlive
touch "$fx/forge/queue-strict"
qpages() { # entries file -> one page per entry, with the deployed paging envelope
  local total n i
  total=$(jq length "$1")
  for ((i = 0; i < total; i++)); do
    n=$((i + 1))
    jq -c --argjson i "$i" --argjson n "$n" --argjson total "$total" \
      '{entries: [.[$i]], total: $total, page: {has_more: ($n < $total), limit: 1, page: $n, total: $total}}' \
      "$1" >"$fx/forge/queue-page-$n.json"
  done
}
qpages "$fx/forge/queue.json"
: >"$fx/forge/global-queue.log"; : >"$fx/forge/queue-rejected-keys.log"; : >"$fx/curl.log"
qticket refs/queue/main/2 "$QQ2" "$QBASE"; before=$(scores); run
must 'the live stack is read from the per-repository route and audited' test "$(scores)" == "$((before + 1))"
must 'the route is asked with only the keys it accepts' test ! -s "$fx/forge/queue-rejected-keys.log"
must 'the global merge-queue listing is never read for a repository ticket' test ! -s "$fx/forge/global-queue.log"
must 'every page of the per-repository listing is followed' \
  test "$(grep -c 'repos/acme%2Fqrepo/merge-queue?' "$fx/curl.log")" == 2
must 'the entry below the ticketed one came from the second page' \
  grep -q 'merge-queue?per_page=500&page=2' "$fx/curl.log"
for status in 422 503; do
  printf '%s\n' "$status" >"$fx/forge/queue-refuses"
  : >"$fx/checkout.log"; before=$(scores)
  qticket refs/queue/main/2 "$QQ2" "$QBASE"; run
  must "a route answering $status refuses the ticket" grep -q "the forge answered $status listing its merge queue" "$fx/out"
  must "a route answering $status checks out nothing" test ! -s "$fx/checkout.log"
  must "a route answering $status submits nothing" test "$(scores)" == "$before"
done
rm -f "$fx/forge/queue-refuses" "$fx/forge/queue-page-"*.json "$fx/forge/queue-strict"
printf 'PASS the per-repository listing route, its paging envelope and its strict query keys are the consumed contract\n'

# --- the audit base the forge dispatches ------------------------------------------------------------
# For a queue ref, plan_push_audit (ci_bridge/audit_queue.rs: `base = merge-base refs/heads/<base
# branch> <queue sha>`) tickets the fork of the queue commit with the base branch, not the branch tip
# and not the entry's replay parent. Advance main past the stack so the three differ, and prove the
# host admits exactly that commit.
qlive
QMAIN2=$(qcommit main-moved "$QBASE")
git -C "$qw" push -q "$fx/git/qrepo.git" "$QMAIN2:refs/heads/main"
QDISPATCH=$(git -C "$fx/git/qrepo.git" merge-base refs/heads/main "$QQ2")
must 'the forge dispatch base is the queue stack bottom' test "$QDISPATCH" == "$QBASE"
must 'the moved main tip is not that base' test "$QMAIN2" != "$QDISPATCH"
: >"$fx/jankurai.log"; before=$(scores)
qticket refs/queue/main/2 "$QQ2" "$QDISPATCH"; run
must 'the dispatched base is admitted while main is ahead of the stack' test "$(scores)" == "$((before + 1))"
must 'the audit diffs the queue head against that dispatched base' \
  grep -q "diff-audit .* --base-ref $QDISPATCH " "$fx/jankurai.log"
must 'the proof is published for the queue head' \
  test "$(jq -r '[.branch, .commit_sha, .base_sha] | join(" ")' "$fx/forge/score-$before.json")" == "refs/queue/main/2 $QQ2 $QDISPATCH"
for wrong in "$QMAIN2" "$QQ1"; do
  : >"$fx/checkout.log"; before=$(scores)
  qticket refs/queue/main/2 "$QQ2" "$wrong"; run
  must 'a base off the dispatched fork is refused' grep -q 'audit range does not cover the queue stack' "$fx/out"
  must 'a base off the dispatched fork checks out nothing' test ! -s "$fx/checkout.log"
  must 'a base off the dispatched fork submits nothing' test "$(scores)" == "$before"
done
git -C "$fx/git/qrepo.git" update-ref refs/heads/main "$QBASE"
printf 'PASS the forge-selected queue audit base is admitted and audited, and other bases are refused\n'

# Version errors are operational failures, distinct from forged queue content.
for version in 'git version 2.39.5' 'git version 2.38.0' 'unrecognized-version'; do
  printf '%s\n' "$version" >"$fx/git-version"
  : >"$fx/checkout.log"; before=$(scores)
  qticket refs/queue/main/2 "$QQ2" "$QBASE"; run
  must 'unsupported Git is reported loudly as a tool-version error' grep -q 'tool-version error: queue replay verification requires Git >= 2.40' "$fx/out"
  must 'unsupported Git is never reported as a forged queue tree' test "$(grep -c 'queue tree does not match' "$fx/out" || true)" == 0
  must 'unsupported Git checks out nothing' test ! -s "$fx/checkout.log"
  must 'unsupported Git submits no proof' test "$(scores)" == "$before"
done
printf 'git version 2.40.0\n' >"$fx/git-version"
qticket refs/queue/main/2 "$QQ2" "$QBASE"; before=$(scores); run
must 'Git 2.40 meets the replay-verifier requirement' test "$(scores)" == "$((before + 1))"
rm "$fx/git-version"
printf 'PASS unsupported Git produces an explicit host tool-version error before replay checkout\n'

# A vendor build can report a recent version while lacking the required option.
touch "$fx/no-merge-base"
: >"$fx/checkout.log"; before=$(scores)
qticket refs/queue/main/2 "$QQ2" "$QBASE"; run
must 'missing merge-base capability has a repair diagnostic' grep -q 'tool-capability error:.*install Git >= 2.40' "$fx/out"
must 'missing capability checks out nothing' test ! -s "$fx/checkout.log"
must 'missing capability submits nothing' test "$(scores)" == "$before"
rm "$fx/no-merge-base"

for failure in 1 128; do
  printf '%s\n' "$failure" >"$fx/merge-failure"
  : >"$fx/checkout.log"; before=$(scores)
  qticket refs/queue/main/2 "$QQ2" "$QBASE"; run
  diagnostic='unsupported replay:'
  [[ "$failure" == 1 ]] || diagnostic='tool-reconstruction error:'
  must 'reconstruction failures explain the operator action' grep -q "$diagnostic" "$fx/out"
  must 'reconstruction failures check out nothing' test ! -s "$fx/checkout.log"
  must 'reconstruction failures submit nothing' test "$(scores)" == "$before"
done
rm "$fx/merge-failure"

# Sequential rename then replacement preserves a main edit in the renamed file;
# an aggregate three-way merge instead preserves it in the original file.
saved_base=$QBASE saved_src=$QSRC1 saved_queue=$QQ1
qgit checkout -q --detach "$QFORK"
printf 'start\n' >"$qw/name"; qgit add name; qgit commit -q -m name
cfork=$(qgit rev-parse HEAD)
qgit mv name renamed; qgit commit -q -m rename
rename_sha=$(qgit rev-parse HEAD)
printf 'start\n' >"$qw/name"; qgit add name; qgit commit -q -m replacement
QSRC1=$(qgit rev-parse HEAD)
qgit checkout -q --detach "$cfork"
printf 'main edit\n' >"$qw/name"; qgit add name; qgit commit -q -m edit
QBASE=$(qgit rev-parse HEAD)
qgit cherry-pick "$rename_sha" "$QSRC1"
QQ1=$(qgit rev-parse HEAD)
qgit push -q "$fx/git/qrepo.git" "+$QBASE:refs/heads/main" "+$QSRC1:refs/pull/1/head" "+$QQ1:refs/queue/main/1"
qlive
jq '[.[0]]' "$fx/forge/queue.json" >"$fx/forge/q.tmp"; mv "$fx/forge/q.tmp" "$fx/forge/queue.json"
: >"$fx/checkout.log"; before=$(scores)
qticket refs/queue/main/1 "$QQ1" "$QBASE"; run
must 'a legitimate sequential replay difference is diagnosed distinctly' grep -q 'unsupported complex replay:.*simplify the source history' "$fx/out"
must 'unsupported complex replay checks out nothing' test ! -s "$fx/checkout.log"
must 'unsupported complex replay submits nothing' test "$(scores)" == "$before"
QBASE=$saved_base QSRC1=$saved_src QQ1=$saved_queue
qgit push -q "$fx/git/qrepo.git" "+$QBASE:refs/heads/main" "+$QSRC1:refs/pull/1/head" "+$QQ1:refs/queue/main/1"
qlive

before=$(scores)
git -C "$fx/git/qrepo.git" update-ref refs/queue/main/2 "$QQ1"
qticket refs/queue/main/2 "$QQ2" "$QBASE"
run
must 'a queue ref that moved since the ticket is refused' grep -q 'no longer names the ticketed commit' "$fx/out"
must 'a moved queue ref submits nothing' test "$(scores)" == "$before"
git -C "$fx/git/qrepo.git" update-ref refs/queue/main/2 "$QQ2"
qticket refs/queue/main/2 "$QSRC2" "$QQ1"
run
must 'a ticket whose sha is not the live entry s is refused' grep -q 'merge queue holds no building entry refs/queue/main/2' "$fx/out"
qticket refs/queue/main/1 "$QQ2" "$QQ1"
run
must 'a ref and sha that belong to different entries are refused' grep -q 'merge queue holds no building entry refs/queue/main/1' "$fx/out"
qticket refs/queue/main/2 "$QQ2" "$QBASE"
jq 'map(if .number == 2 then .state = "landed" else . end)' "$fx/forge/queue.json" >"$fx/forge/queue.tmp"; mv "$fx/forge/queue.tmp" "$fx/forge/queue.json"
run
must 'an entry the queue no longer builds is refused' grep -q 'merge queue holds no building entry' "$fx/out"
qlive
jq 'map(select(.number != 2))' "$fx/forge/pulls-raw.json" >"$fx/forge/pulls.tmp"; mv "$fx/forge/pulls.tmp" "$fx/forge/pulls-raw.json"
qticket refs/queue/main/2 "$QQ2" "$QBASE"
run
must 'a source pull request that is no longer open is refused' grep -q "no open pull request #2 holds the head" "$fx/out"
printf 'PASS stale, mismatched and dequeued queue tickets are refused\n'

qlive '["origin:contributed"]'
: >"$fx/git-helper.log"; before=$(scores)
qticket refs/queue/main/2 "$QQ2" "$QBASE"
run
must 'a stack holding a contribution is refused' grep -q 'a contribution (origin:contributed) is in the stack under refs/queue/main/2' "$fx/out"
must 'a contributed stack is never cloned' test ! -s "$fx/git-helper.log"
must 'a contributed stack submits nothing' test "$(scores)" == "$before"
qlive '[]'
qticket refs/queue/main/2 "$QQ2" "$QBASE"
run
must 'a stack source the forge does not mark internal is refused' grep -q 'is not marked origin:internal' "$fx/out"
must 'an unmarked stack is never cloned' test ! -s "$fx/git-helper.log"

printf 'PASS a contributed or unmarked source anywhere in the stack refuses the queue ticket\n'

# --- duplicate and unlistable source rows ------------------------------------------------------------
# Two open rows for the same number, disagreeing about the marking: the host must not audit the stack
# on the strength of whichever row the listing put first.
for order in internal-first contributed-first; do
  qlive
  jq -n --arg s1 "$QSRC1" --arg s2 "$QSRC2" --arg order "$order" \
    '[{number:1,head_sha:$s1,labels:["origin:internal"]},{number:1,head_sha:$s1,labels:["origin:contributed"]}]
     | (if $order == "contributed-first" then reverse else . end)
     + [{number:2,head_sha:$s2,labels:["origin:internal"]}]' >"$fx/forge/pulls-raw.json"
  : >"$fx/git-helper.log"; : >"$fx/jankurai.log"; before=$(scores)
  qticket refs/queue/main/2 "$QQ2" "$QBASE"
  run
  must "duplicate rows ($order) refuse the ticket" \
    grep -q 'reports more than one open pull request #1 under refs/queue/main/2' "$fx/out"
  must "duplicate rows ($order) are never resolved to the internal one" \
    test "$(grep -c "acme/qrepo@$QQ2 scored" "$fx/out" || true)" == 0
  must "duplicate rows ($order) are never cloned" test ! -s "$fx/git-helper.log"
  must "duplicate rows ($order) submit nothing" test "$(scores)" == "$before"
done
# The same listing repeated across pages is not a disagreement: identical rows resolve as one.
qlive
jq '. + [.[0]]' "$fx/forge/pulls-raw.json" >"$fx/forge/pulls.tmp"; mv "$fx/forge/pulls.tmp" "$fx/forge/pulls-raw.json"
before=$(scores); qticket refs/queue/main/2 "$QQ2" "$QBASE"; run
must 'a row repeated byte for byte still admits the stack' grep -q "acme/qrepo@$QQ2 scored" "$fx/out"
must 'a repeated row is audited once' test "$(scores)" == "$((before + 1))"
printf 'PASS duplicate source rows that disagree refuse the ticket instead of picking the internal one\n'

# A repository with more open pull requests than this host can page: every page reports another after
# it, so no accumulated listing exists. The stack is still resolved, by number, and admission is
# unchanged -- the same head binding, the same marking, the same refusal of a contribution.
pr_row() { # number head labels [state] [merged]
  jq -n --argjson n "$1" --arg h "$2" --argjson l "$3" --arg st "${4:-open}" --argjson m "${5:-false}" \
    '{number:$n,head_sha:$h,labels:$l,state:$st,merged:$m}' >"$fx/forge/pr-$1.json"
}
qlive; : >"$fx/forge/listing-overflow"
pr_row 1 "$QSRC1" '["origin:internal"]'; pr_row 2 "$QSRC2" '["origin:internal"]'
before=$(scores); : >"$fx/curl.log"; qticket refs/queue/main/2 "$QQ2" "$QBASE"; run
must 'an unlistable repository is still admitted through the per-number route' grep -q "acme/qrepo@$QQ2 scored" "$fx/out"
must 'the unlistable stack is submitted under its exact queue ref and sha' \
  test "$(jq -r '[.branch, .commit_sha] | join(" ")' "$fx/forge/score-$before.json")" == "refs/queue/main/2 $QQ2"
must 'the per-number route is the one read for each source' \
  test "$(grep -c 'GET https://forge.example.test/api/v1/repos/acme%2Fqrepo/pulls/[12]$' "$fx/curl.log")" -ge 2
must 'paging stopped at the bound this host reads' \
  test "$(grep -c 'repos/acme%2Fqrepo/pulls?state=open&per_page=500&page=' "$fx/curl.log")" == 20
# Nothing about full-stack admission is relaxed by that route.
pr_row 1 "$QSRC1" '["origin:contributed"]'
: >"$fx/git-helper.log"; before=$(scores); qticket refs/queue/main/2 "$QQ2" "$QBASE"; run
must 'an unlistable stack holding a contribution is refused' \
  grep -q 'a contribution (origin:contributed) is in the stack under refs/queue/main/2' "$fx/out"
must 'an unlistable contributed stack is never cloned' test ! -s "$fx/git-helper.log"
must 'an unlistable contributed stack submits nothing' test "$(scores)" == "$before"
pr_row 1 "$QSRC1" '[]'
before=$(scores); qticket refs/queue/main/2 "$QQ2" "$QBASE"; run
must 'an unlistable unmarked source is refused' grep -q 'is not marked origin:internal' "$fx/out"
must 'an unlistable unmarked source submits nothing' test "$(scores)" == "$before"
pr_row 1 "$QSRC1" '["origin:internal"]' closed true
before=$(scores); qticket refs/queue/main/2 "$QQ2" "$QBASE"; run
must 'a merged source is not an open pull request' grep -q "no open pull request #1 holds the head ${QSRC1:0:12}" "$fx/out"
must 'a merged source submits nothing' test "$(scores)" == "$before"
pr_row 1 "$QSRC1" '["origin:internal"]'
jq '.head_sha = "'"$QQ1"'"' "$fx/forge/pr-1.json" >"$fx/forge/pr.tmp"; mv "$fx/forge/pr.tmp" "$fx/forge/pr-1.json"
before=$(scores); qticket refs/queue/main/2 "$QQ2" "$QBASE"; run
must 'a per-number row with another head does not bind the queued source' \
  grep -q "no open pull request #1 holds the head ${QSRC1:0:12}" "$fx/out"
must 'a mismatched head submits nothing' test "$(scores)" == "$before"
rm -f -- "$fx/forge/listing-overflow" "$fx/forge/pr-1.json" "$fx/forge/pr-2.json"
printf 'PASS a repository too large to list resolves its queue sources by number, with the same bindings\n'

# Even a response using base-branch-tip semantics must not undercount a hidden contribution.
qlive '["origin:contributed"]'
jq --arg b "$QBASE" 'map(if .number == 2 then .base_sha = $b else . end)' \
  "$fx/forge/queue.json" >"$fx/forge/queue.tmp"; mv "$fx/forge/queue.tmp" "$fx/forge/queue.json"
: >"$fx/checkout.log"; before=$(scores)
qticket refs/queue/main/2 "$QQ2" "$QBASE"; run
must 'base-tip semantics cannot hide an earlier source in the queue tree' grep -q 'queue tree does not match its declared source replay' "$fx/out"
must 'a hidden source is never checked out' test ! -s "$fx/checkout.log"
must 'a hidden source produces no score' test "$(scores)" == "$before"
# Nor may a queue ref carry extra bytes even if every declared PR is internal.
qlive
QEXTRA=$(qcommit hidden "$QQ2")
git -C "$qw" push -q "$fx/git/qrepo.git" "$QEXTRA:refs/queue/main/2"
jq --arg q "$QEXTRA" 'map(if .number == 2 then .queue_sha = $q else . end)' \
  "$fx/forge/queue.json" >"$fx/forge/queue.tmp"; mv "$fx/forge/queue.tmp" "$fx/forge/queue.json"
: >"$fx/checkout.log"
qticket refs/queue/main/2 "$QEXTRA" "$QBASE"; run
must 'extra queue bytes are refused' grep -q 'queue tree does not match its declared source replay' "$fx/out"
must 'extra queue bytes are never checked out' test ! -s "$fx/checkout.log"
git -C "$fx/git/qrepo.git" update-ref refs/queue/main/2 "$QQ2"
printf 'PASS fetched queue trees must match declared reviewed source replays before checkout\n'

# A missing/non-building parent is not evidence of a reviewed replay base. Prove the bottom on main
# after fetch, before checkout, even when the missing ancestor's source was a contribution.
for state in landed failed dequeued missing; do
  qlive '["origin:contributed"]'
  jq --arg state "$state" 'if $state == "missing" then map(select(.number != 1))
    else map(if .number == 1 then .state = $state else . end) end' "$fx/forge/queue.json" >"$fx/forge/queue.tmp"
  mv "$fx/forge/queue.tmp" "$fx/forge/queue.json"
  : >"$fx/checkout.log"; : >"$fx/jankurai.log"; before=$(scores)
  qticket refs/queue/main/2 "$QQ2" "$QBASE"
  run
  must "a $state ancestor outside main is refused" grep -q 'queue stack bottom is not on main' "$fx/out"
  must "a $state ancestor outside main is never checked out" test ! -s "$fx/checkout.log"
  must "a $state ancestor outside main is never audited" test ! -s "$fx/jankurai.log"
  must "a $state ancestor outside main submits nothing" test "$(scores)" == "$before"
done
for parent in absent not-a-sha; do
  qlive
  jq --arg parent "$parent" 'map(if .number == 1 then
    (if $parent == "absent" then del(.base_sha) else .base_sha = $parent end) else . end)' \
    "$fx/forge/queue.json" >"$fx/forge/queue.tmp"
  mv "$fx/forge/queue.tmp" "$fx/forge/queue.json"
  : >"$fx/git-helper.log"
  qticket refs/queue/main/2 "$QQ2" "$QBASE"; run
  must "a $parent stack base is malformed" grep -q 'a queue entry under refs/queue/main/2 is malformed' "$fx/out"
  must "a $parent stack base is refused before clone" test ! -s "$fx/git-helper.log"
done
# A genuinely landed ancestor is trusted without an open PR row: its queue commit is now on main.
qlive
jq 'map(select(.number != 1))' "$fx/forge/queue.json" >"$fx/forge/queue.tmp"; mv "$fx/forge/queue.tmp" "$fx/forge/queue.json"
git -C "$fx/git/qrepo.git" update-ref refs/heads/main "$QQ1"
qticket refs/queue/main/2 "$QQ2" "$QBASE"; before=$(scores); run
must 'a reviewed stack bottom already on main is admitted' test "$(scores)" == "$((before + 1))"
git -C "$fx/git/qrepo.git" update-ref refs/heads/main "$QBASE"
qlive
qticket refs/queue/main/2 "$QQ2" "$QQ1"; before=$(scores); : >"$fx/checkout.log"; run
must 'a ticket diff base must cover its entire live stack' grep -q 'audit range does not cover the queue stack' "$fx/out"
must 'a partial stack range is never checked out' test ! -s "$fx/checkout.log"
must 'a partial stack range submits nothing' test "$(scores)" == "$before"
jq 'map(if .number == 2 then .number = 3 else . end)' "$fx/forge/queue.json" >"$fx/forge/queue.tmp"; mv "$fx/forge/queue.tmp" "$fx/forge/queue.json"
qticket refs/queue/main/2 "$QQ2" "$QBASE"; run
must 'a ref number must match its entry' grep -q 'does not match the ticket ref' "$fx/out"
printf 'PASS queue stacks require a well-formed bottom on main before checkout and a range covering the whole stack\n'

# The whole response must not be passed through argv, whose single-argument limit is only 128 KiB.
qlive
jq '. + [range(10; 3010) | {number:.,head_sha:"0000000000000000000000000000000000000000",title:("x" * 1000)}]' \
  "$fx/forge/pulls-raw.json" >"$fx/forge/pulls.tmp"; mv "$fx/forge/pulls.tmp" "$fx/forge/pulls-raw.json"
qticket refs/queue/main/2 "$QQ2" "$QBASE"; before=$(scores); run
must 'a multi-megabyte PR listing is admitted without argv overflow' test "$(scores)" == "$((before + 1))"
printf 'PASS large forge listings do not use argv for JSON accumulation\n'

# Bound queue jobs must agree with the job's authoritative origin as well as source labels.
qlive
SSHA=$(stage); touch "$fx/forge/bound"
mv "$fx/install/pr-gate-ensure-jankurai.sh" "$fx/verifier.bound-off"
bticket qrepo "$QBASE" "$QQ2" "$QBASE" "$DEFAULT_SHA" internal proof "$SSHA" 9.9.9 refs/queue/main/2
before=$(scores); run
must 'a bound internal queue job is admitted with real binding' test "$(scores)" == "$((before + 1))"
must 'a bound queue proof names the exact queue SHA and job' test "$(last_score | jq -r '[.head_sha,.job_id] | join(" ")')" == "$QQ2 job-${QQ2:0:8}"
printf 'git version 2.39.5\n' >"$fx/git-version"
bticket qrepo "$QBASE" "$QQ2" "$QBASE" "$DEFAULT_SHA" internal proof "$SSHA" 9.9.9 refs/queue/main/2
: >"$fx/checkout.log"; before=$(scores); run
must 'a bound job with unsupported Git is released as a verifier mismatch' test "$(released | cut -d' ' -f2)" == verifier-mismatch
must 'its heartbeat names the host tool-version error' test "$(last_beat | jq -r .last.reason)" == 'verifier-mismatch: tool-version error: queue replay verification requires Git >= 2.40; found git version 2.39.5'
must 'the bound version failure checks out nothing' test ! -s "$fx/checkout.log"
must 'the bound version failure submits nothing' test "$(scores)" == "$before"
rm "$fx/git-version"
# This fixture already has a sandbox configured: a contribution remains refused for the queue path.
bticket qrepo "$QBASE" "$QQ2" "$QBASE" "$DEFAULT_SHA" contributed proof "$SSHA" 9.9.9 refs/queue/main/2
: >"$fx/git-helper.log"; before=$(scores); run
must 'a bound queue job with contributed origin is released' test "$(released | cut -d' ' -f2)" == contributed
must 'a bound contributed queue job is never cloned' test ! -s "$fx/git-helper.log"
must 'a bound contributed queue job submits nothing' test "$(scores)" == "$before"
# Every bound queue refusal uses the existing ADR0011 vocabulary and releases immediately.
for scenario in missing malformed unmarked listing-404 pulls-404 listing-unreadable stale range bottom content duplicate; do
  qlive
  bbranch=refs/queue/main/2; bbase=$QBASE
  case "$scenario" in
    missing) printf '[]\n' >"$fx/forge/queue.json" ;;
    malformed) jq 'map(if .number == 2 then del(.base_sha) else . end)' "$fx/forge/queue.json" >"$fx/forge/q.tmp"; mv "$fx/forge/q.tmp" "$fx/forge/queue.json" ;;
    unmarked) qlive '[]' ;;
    listing-404) printf '404\n' >"$fx/forge/queue.status" ;;
    pulls-404) printf '404\n' >"$fx/forge/pulls.status" ;;
    listing-unreadable) printf 'malformed\n' >"$fx/forge/queue.status" ;;
    stale) git -C "$fx/git/qrepo.git" update-ref refs/queue/main/2 "$QQ1" ;;
    range) bbase=$QQ1 ;;
    bottom) jq 'map(select(.number != 1))' "$fx/forge/queue.json" >"$fx/forge/q.tmp"; mv "$fx/forge/q.tmp" "$fx/forge/queue.json" ;;
    content) jq --arg b "$QBASE" 'map(if .number == 2 then .base_sha = $b else . end)' "$fx/forge/queue.json" >"$fx/forge/q.tmp"; mv "$fx/forge/q.tmp" "$fx/forge/queue.json" ;;
    duplicate) jq '. + [.[1]]' "$fx/forge/queue.json" >"$fx/forge/q.tmp"; mv "$fx/forge/q.tmp" "$fx/forge/queue.json" ;;
  esac
  bticket qrepo "$bbase" "$QQ2" "$QBASE" "$DEFAULT_SHA" internal proof "$SSHA" 9.9.9 "$bbranch"
  : >"$fx/forge/releases.log"; : >"$fx/checkout.log"; before=$(scores); run
  want=malformed-ticket; [[ "$scenario" != bottom ]] || want=not-on-main
  must "bound queue $scenario releases exactly once" test "$(wc -l <"$fx/forge/releases.log")" == 1
  must "bound queue $scenario is released immediately" test "$(released | cut -d' ' -f2)" == "$want"
  must "bound queue $scenario is never checked out" test ! -s "$fx/checkout.log"
  must "bound queue $scenario produces no score" test "$(scores)" == "$before"
  rm -f "$fx/forge/pulls.status" "$fx/forge/queue.status"
  git -C "$fx/git/qrepo.git" update-ref refs/queue/main/2 "$QQ2"
done
# A transient forge answer says nothing about the ticket. Such a listing failure must never hand a
# valid queue job back as malformed data (a released job is never scored): it is left to its lease so
# a later pass retries it, and the very same ticket is audited once the forge answers again.
for listing in queue pulls; do
  for fault in 429 503 timeout; do
    qlive
    printf '%s\n' "$fault" >"$fx/forge/$listing.status"
    bticket qrepo "$QBASE" "$QQ2" "$QBASE" "$DEFAULT_SHA" internal proof "$SSHA" 9.9.9 refs/queue/main/2
    : >"$fx/forge/releases.log"; : >"$fx/checkout.log"; : >"$fx/jankurai.log"; before=$(scores); run
    must "a $fault listing $listing hands nothing back" test ! -s "$fx/forge/releases.log"
    must "a $fault listing $listing leaves the ticket to its lease" grep -q 'leaving the ticket to its lease to retry' "$fx/out"
    must "a $fault listing $listing is never called malformed" test "$(grep -c malformed "$fx/out" || true)" == 0
    must "a $fault listing $listing checks out nothing" test ! -s "$fx/checkout.log"
    must "a $fault listing $listing audits nothing" test ! -s "$fx/jankurai.log"
    must "a $fault listing $listing submits nothing" test "$(scores)" == "$before"
    rm -f "$fx/forge/$listing.status" "$fx/home/cache/forge-backoff"
    bticket qrepo "$QBASE" "$QQ2" "$QBASE" "$DEFAULT_SHA" internal proof "$SSHA" 9.9.9 refs/queue/main/2
    before=$(scores); run
    must "the ticket held through a $fault listing $listing is still audited" test "$(scores)" == "$((before + 1))"
  done
done
printf 'PASS transient listing failures keep a valid queue ticket claimable instead of discarding it\n'

# A legal ordinary branch named queue/main/2 is not the forge's canonical refs/queue ref.
# The head is advertised by the bare repository as refs/heads/queue/main/2, so a clone carries it by
# ordinary branch reachability rather than through refs/queue.
git -C "$fx/git/qrepo.git" update-ref refs/heads/queue/main/2 "$QQ2"
git -C "$fx/git/qrepo.git" update-ref -d refs/queue/main/2
bticket qrepo "$QBASE" "$QQ2" "$QBASE" "$DEFAULT_SHA" internal proof "$SSHA" 9.9.9 queue/main/2
: >"$fx/curl.log"; before=$(scores); run
must 'a queue-shaped ordinary branch remains an ordinary bound PR' test "$(scores)" == "$((before + 1))"
must 'an ordinary branch does not consult the merge queue' test "$(grep -c '/merge-queue?' "$fx/curl.log" || true)" == 0
git -C "$fx/git/qrepo.git" update-ref refs/queue/main/2 "$QQ2"
git -C "$fx/git/qrepo.git" update-ref -d refs/heads/queue/main/2
printf 'PASS bound queue refusals release known reasons without checkout; ordinary queue-named branches stay ordinary\n'
rm -f "$fx/forge/bound"; mv "$fx/verifier.bound-off" "$fx/install/pr-gate-ensure-jankurai.sh"
printf 'PASS bound queue admission retains authoritative origin refusal even with a sandbox\n'

rm -f "$fx/forge/pulls-raw.json" "$fx/forge/queue.json"
