#!/usr/bin/env bash
# Exercise pr-gate-audit.sh against a fixture forge, a local bare repository behind the forge's git
# URL, a stand-in governed jankurai and a stand-in verifier: claim, audit in a throwaway clone, submit
# the report from a file (one larger than a single argv string may be), beat /runners, and stay
# harmless when the forge refuses, lacks the routes or asks for a back-off.
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
src_bin=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
fx=$(mktemp -d)
trap 'rm -rf -- "$fx"' EXIT
mkdir -p "$fx/install" "$fx/bin" "$fx/home" "$fx/forge" "$fx/git"
for f in pr-gate-audit.sh pr-gate-config.sh pr-gate-backoff.sh pr-gate-state.sh; do cp "$src_bin/$f" "$fx/install/"; done
audit="$fx/install/pr-gate-audit.sh"
printf 'AUDIT-TOKEN-5c1e\n' >"$fx/token"; chmod 0600 "$fx/token"
printf 'PR_GATE_FORGE_URL=https://forge.example.test\nJERYU_TOKEN_FILE=%s\nGATE_RUNNER_IDENTITY=gate-bot\n' "$fx/token" >"$fx/pr-gate.env"
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
if [[ "\${1:-}" == clone ]]; then
  printf '%s\n' "\${GIT_CONFIG_VALUE_1:-}" >>"$fx/git-helper.log"
  args=(); for a in "\$@"; do args+=("\${a/https:\/\/forge.example.test\/git\/acme\//$fx/git/}"); done
  exec "$real_git" "\${args[@]}"
fi
exec "$real_git" "\$@"
SH
# The stand-in auditor: records how it was called and writes a report padded past 128 KiB, unless
# $fx/tool-fails says to write nothing and exit 3.
cat >"$fx/bin/jankurai" <<SH
#!/usr/bin/env bash
[[ "\${1:-}" != --version ]] || { echo 'jankurai 9.9.9'; exit 0; }
printf '%s|%s\n' "\$PWD" "\$*" >>"$fx/jankurai.log"
tree=.; [[ "\${1:-}" != diff-audit ]] || tree=\$2
cat "\$tree/agent/audit-policy.toml" >"$fx/policy.seen" 2>/dev/null || true
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
  */jankurai-audits/claim)
    if [[ -e "$fx/forge/claim.status" ]]; then answer nope "\$(cat "$fx/forge/claim.status")"
    elif [[ -e "$fx/forge/claim.json" ]]; then answer "\$(cat "$fx/forge/claim.json")" 200; rm -f "$fx/forge/claim.json"
    else answer '{"leaseSeconds":1800,"tickets":[]}' 200; fi;;
  */jankurai-scores)
    n=0; for f in "$fx"/forge/score-*.json; do [[ -e "\$f" ]] && n=\$((n + 1)); done
    cp "\${data#@}" "$fx/forge/score-\$n.json"
    printf '%s\n' "\${data#@}" >>"$fx/score-bodies.log"
    answer '{"score":91}' "\$(cat "$fx/forge/score.status" 2>/dev/null || echo 201)";;
  */runners/heartbeat) cat >>"$fx/forge/beats.jsonl"; printf '\n' >>"$fx/forge/beats.jsonl"; answer '' 200;;
  *) answer nope 404;;
esac
SH
chmod +x "$fx/bin/git" "$fx/bin/jankurai" "$fx/bin/curl"

run() { cd "$fx" && HOME="$fx/home" PATH="$fx/bin:$PATH" GATE_RUNNER_HOME="$fx/home" PR_GATE_CONFIG="$fx/pr-gate.env" \
  bash "$audit" >"$fx/out" 2>&1; }
must() { local why=$1; shift; "$@" || { printf 'FAIL: %s\n' "$why" >&2; cat "$fx/out" >&2; exit 1; }; }
scores() { local n=0 f; for f in "$fx"/forge/score-*.json; do [[ -e "$f" ]] && n=$((n + 1)); done; echo "$n"; }
ticket() { # mode
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
must 'the diff audit ran against the ticketed base' grep -q "diff-audit .* --base-ref $BASE_SHA .*--advisory-only" "$fx/jankurai.log"
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
must 'the full audit audits the whole tree' grep -q '| *audit \. --json' "$fx/jankurai.log"
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
set +e; run; rc=$?; set -e
must 'no verifier, no audit' test "$rc" == 2
must 'it says the verifier is missing' grep -q 'pr-gate-ensure-jankurai.sh is not installed' "$fx/out"
printf 'PASS a host without the verifier audits nothing\n'
