#!/usr/bin/env bash
# A release pin bump (a change to release lock files only) is reviewed once its required contexts
# have a result, never before, and never later than REDTEAM_PIN_WAIT_SECS after a pass first saw its
# head. While it waits nothing is recorded, posted or spent. Every other head is reviewed at once,
# as is a pin bump whose contexts already have a result (a failing one included). The review is
# told each required context's state. Offline: stand-in forge, git and model processes.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
finish() {
  local result=$?
  if ((result != 0)); then tail -60 "$t/controller.log" 2>/dev/null || true; fi
  rm -rf -- "$t"
}
trap finish EXIT
fail() { echo "FAIL $1" >&2; exit 1; }
real_git="$(command -v git)"
fixture_git() {
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_AUTHOR_DATE \
    -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL -u GIT_COMMITTER_DATE "$real_git" "$@"
}
mkdir -p "$t/bin" "$t/state" "$t/repo"
printf 'fixture-bearer\n' >"$t/token"
fixture_git init -q -b main "$t/repo"
g() { fixture_git -C "$t/repo" -c user.name=fixture -c user.email=fixture@example.invalid "$@"; }
printf 'base\n' >"$t/repo/README.md"
printf '[[repo]]\nname = "web"\ncommit = "%s"\n' "$(printf 'a%.0s' {1..40})" >"$t/repo/acme.lock.toml"
g add .; g commit -qm base; g rev-parse HEAD >"$t/base"
g switch -qc topic
bump() { printf '# bump %s\n' "$RANDOM$RANDOM" >>"$t/repo/acme.lock.toml"; g commit -qam bump; g rev-parse HEAD >"$t/head"; }
bump
printf 'main\n' >"$t/base-ref"
g branch release/pilot "$(cat "$t/base")"
g branch release/unchanged "$(cat "$t/base")"

cat >"$t/bin/git" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  case "$arg" in
    push|rebase|--force-with-lease*) echo forbidden-history-write >>"$PIN_FIXTURE/danger"; exit 97 ;;
    https://forge.invalid/git/acme/fixture.git) args+=("$PIN_FIXTURE/repo") ;;
    *) args+=("$arg") ;;
  esac
done
exec "$FIXTURE_REAL_GIT" "${args[@]}"
FIXTURE
cat >"$t/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
method=GET data=''
while (($#)); do
  case "$1" in
    --config) [[ "$2" != - ]] || cat >/dev/null; shift ;;
    -X) method="$2"; shift ;;
    --data) data="$2"; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
printf '%s %s\n' "$method" "$url" >>"$PIN_FIXTURE/requests"
head="$(cat "$PIN_FIXTURE/head")"
case "$url" in
  */api/v3/user) printf '{"login":"independent-reviewer"}\n200' ;;
  *'/pulls?state=open')
    jq -nc --arg sha "$head" --arg base "$(cat "$PIN_FIXTURE/base")" --arg base_ref "$(cat "$PIN_FIXTURE/base-ref")" --slurpfile ctx "$PIN_FIXTURE/contexts" \
      '{items: [{repo: {owner: "acme", name: "fixture"}, number: 1, head_sha: $sha, base_sha: $base,
        head_ref: "topic", base_ref: $base_ref, draft: false, author: "pinbot", title: "release: pin web",
        state: "open", labels: ["origin:internal"], passport_hash: "p", review: {changes_requested: 0},
        mergeable: {can_merge: false}}
        + (if $ctx[0] == "absent" then {} else {required_contexts: $ctx[0]} end)]}'
    printf '\n200' ;;
  */pulls/1/diff)
    if [[ -e "$PIN_FIXTURE/diff-down" ]]; then printf '{"message":"unavailable"}\n503'; exit 0; fi
    jq -nc --arg sha "$(if [[ -e "$PIN_FIXTURE/diff-stale" ]]; then echo stale; else echo "$head"; fi)" \
      --argjson truncated "$(test -e "$PIN_FIXTURE/diff-truncated" && echo true || echo false)" \
      --slurpfile files "$PIN_FIXTURE/diff-files" \
      '{head_sha: $sha, base_sha: "b", truncated: $truncated,
        files: ($files[0] | map({path: ., old_path: null, status: "modified", hunks: []}))}'
    printf '\n200' ;;
  */pulls/1) printf '{"merge_passport":{"blockers":[]}}\n200' ;;
  */pulls/1/checks) printf '{"checks":[]}\n200' ;;
  */check-runs) jq -c . <<<"$data" >>"$PIN_FIXTURE/check-runs"; printf '{"id":"c"}\n201' ;;
  */reviews) jq -c . <<<"$data" >>"$PIN_FIXTURE/posts"; printf '{"ok":true}\n201' ;;
  */api/v1/events) printf '{"ok":true}\n201' ;;
  *) printf 'forbidden API %s\n' "$url" >>"$PIN_FIXTURE/danger"; exit 98 ;;
esac
FIXTURE
cat >"$t/bin/model" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then echo '9.9.9 (Claude Code)'; exit 0; fi
PIN_FIXTURE="$(dirname "$(dirname "$0")")"
while (($#)); do [[ "$1" != --add-dir ]] || cp "$2/signals.txt" "$PIN_FIXTURE/signals.txt"; shift; done
printf 'called\n' >>"$PIN_FIXTURE/model-calls"
printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"verdict":"approve","summary":"fixture review","findings":[]}}\n'
FIXTURE
chmod +x "$t/bin/"*
export PIN_FIXTURE="$t" FIXTURE_REAL_GIT="$real_git"
export PATH="$t/bin:$PATH" JERYU_TOKEN_FILE="$t/token" REDTEAM_STATE="$t/state" REDTEAM_CLAUDE="$t/bin/model"
export REDTEAM_CLAUDE_VERSION=9.9.9 REDTEAM_TIMEOUT=10 JERYU_BASE=https://forge.invalid
unset REDTEAM_PIN_WAIT_SECS

review() { "$here/pr-redteam" _review 0 0 0 acme/fixture 1 >>"$t/controller.log" 2>&1; }
receipt() { printf '%s/state/receipts/acme/fixture/1-%s.json\n' "$t" "$(cat "$t/head")"; }
waitfile() { printf '%s/state/pin-wait/acme/fixture/1-%s.json\n' "$t" "$(cat "$t/head")"; }
count() { if [[ -f "$1" ]]; then wc -l <"$1"; else echo 0; fi; }
diff_reads() { grep -c '/pulls/1/diff' "$t/requests" || true; }
contexts() { printf '%s\n' "$1" >"$t/contexts"; }
files() { printf '%s\n' "$1" >"$t/diff-files"; }
reviewed() { # label: the head was reviewed and approved, the model ran once more
  [[ "$(count "$t/model-calls")" == "$calls" ]] && jq -e '.decision == "approve" and .posted == true' "$(receipt)" >/dev/null \
    || fail "$1: not reviewed ($(count "$t/model-calls") model calls; $(cat "$(receipt)" 2>/dev/null))"
}
calls=0

# 1. A pin bump with its required context missing waits: no receipt, review, check run or agent.
contexts '[{"name":"acme/required","state":"missing","details":"required context `acme/required` is missing"}]'
files '["acme.lock.toml"]'
review; review
[[ ! -e "$(receipt)" && "$(count "$t/model-calls")" == 0 && "$(count "$t/posts")" == 0 && "$(count "$t/check-runs")" == 0 ]] \
  || fail "a waiting pin bump was reviewed or recorded"
[[ "$(grep -c 'waiting for required contexts' "$t/controller.log")" == 2 ]] && grep -q 'acme/required (missing)' "$t/controller.log" \
  || fail "the wait was not said: $(cat "$t/controller.log")"
[[ "$(diff_reads)" == 1 ]] && jq -e '.pin_only == true and (.first_seen_epoch | type) == "number"' "$(waitfile)" >/dev/null \
  || fail "the forge's diff was not read exactly once per head ($(diff_reads))"
echo 'ok a pin bump waits while its required context is missing, and the diff is read once per head'

# 2. Pending waits too; once the context succeeds the head is reviewed, and the review sees the result.
contexts '[{"name":"acme/required","state":"pending"}]'; review
[[ "$(count "$t/model-calls")" == 0 ]] || fail "reviewed while pending"
contexts '[{"name":"acme/required","state":"success"}]'; review; calls=1; reviewed "context green"
grep -q '^## required contexts on this head' "$t/signals.txt" && grep -qx 'acme/required: success' "$t/signals.txt" \
  && ! grep -q 'waited' "$t/signals.txt" || fail "signals did not carry the context result: $(cat "$t/signals.txt")"
grep -q "include pr-redteam/review, this reviewer's own check run" "$t/signals.txt" || fail "own check not called out: $(cat "$t/signals.txt")"
echo 'ok once the required context reports, the pin bump is reviewed with the result in signals.txt'

# 3. A failing context is a result: reviewed at once (and the reviewer holds as it sees fit).
bump; contexts '[{"name":"acme/required","state":"failing"}]'; review; calls=2; reviewed "context failing"
grep -qx 'acme/required: failing' "$t/signals.txt" || fail "failing state not shown: $(cat "$t/signals.txt")"
echo 'ok a pin bump whose required context failed is reviewed at once'

# 4. The wait is bounded: past REDTEAM_PIN_WAIT_SECS the head is reviewed, told the context is pending.
bump; contexts '[{"name":"acme/required","state":"pending"}]'; REDTEAM_PIN_WAIT_SECS=600 review
[[ "$(count "$t/model-calls")" == 2 ]] || fail "reviewed inside the bound"
jq --argjson e "$(( $(date +%s) - 601 ))" '.first_seen_epoch = $e' "$(waitfile)" >"$t/w" && cat "$t/w" >"$(waitfile)"
REDTEAM_PIN_WAIT_SECS=600 review; calls=3; reviewed "bound reached"
grep -qx 'acme/required: pending' "$t/signals.txt" \
  && grep -q 'waited [0-9]*s (bound 600s) for its required contexts; still without a result: acme/required (pending)' "$t/signals.txt" \
  || fail "signals did not say the bound ran out: $(cat "$t/signals.txt")"
echo 'ok past the bound a pin bump is reviewed and told its required context is still pending'

# 5. Anything that is not a release-lock-only change is reviewed at once, pending or not.
for case in 'source:["acme.lock.toml","src/main.rs"]' 'nested:["sub/acme.lock.toml"]' 'cargo:["Cargo.lock"]'; do
  bump; contexts '[{"name":"acme/required","state":"pending"}]'; files "${case#*:}"; review; calls=$((calls + 1))
  reviewed "${case%%:*}"
  jq -e '.pin_only == false' "$(waitfile)" >/dev/null || fail "${case%%:*}: recorded as a pin bump"
done
echo 'ok a change that is not release locks only is reviewed at once while its context is pending'

# 6. A forge diff that is stale, truncated or unavailable never makes a head wait.
files '["acme.lock.toml"]'
for flag in diff-stale diff-truncated diff-down; do
  bump; touch "$t/$flag"; review; rm "$t/$flag"; calls=$((calls + 1)); reviewed "$flag"
done
[[ ! -e "$(waitfile)" ]] || fail "an unanswered diff read was recorded"
echo 'ok a stale, truncated or unavailable forge diff reviews at once'

# 7. Off switch, no required contexts, and a forge without the field: reviewed at once, no diff read.
bump; contexts '[{"name":"acme/required","state":"pending"}]'; before="$(diff_reads)"
REDTEAM_PIN_WAIT_SECS=0 review; calls=$((calls + 1)); reviewed "wait off"
bump; contexts '[]'; review; calls=$((calls + 1)); reviewed "none required"
grep -qx '(none required)' "$t/signals.txt" || fail "no-context signal: $(cat "$t/signals.txt")"
bump; contexts '"absent"'; review; calls=$((calls + 1)); reviewed "field absent"
grep -Fq 'gate evidence is unresolved: do not guess contexts' "$t/signals.txt" \
  || fail "missing enforcement data was not identified as unresolved"
[[ "$(diff_reads)" == "$before" ]] || fail "the diff was read with nothing to wait for"
echo 'ok with the wait off or nothing to wait for, the diff is not read and the head is reviewed'

# The forge's enforced context set, not the base's spelling, determines gate evidence.
# These responses model protection on main, a pilot switched to fast, and an unchanged release.
for base_ref in main release/pilot release/unchanged; do
  printf '%s\n' "$base_ref" >"$t/base-ref"
  context=acme/required
  [[ "$base_ref" != release/pilot ]] || context=acme/fast
  bump; contexts "[{\"name\":\"$context\",\"state\":\"pending\"}]"; review
  [[ "$(count "$t/model-calls")" == "$calls" ]] || fail "$base_ref: did not wait for $context"
  contexts "[{\"name\":\"$context\",\"state\":\"success\"}]"; review
  calls=$((calls + 1)); reviewed "$base_ref"
  grep -Fqx "$context: success" "$t/signals.txt" || fail "$base_ref: missing enforced context"
  other=acme/fast; [[ "$context" != acme/fast ]] || other=acme/required
  ! grep -q "^$other:" "$t/signals.txt" || fail "$base_ref: guessed $other"
  grep -Fq "Base branch: \"$base_ref\"." "$t/signals.txt" || fail "$base_ref: missing base"
  grep -Fq 'an upstream commit merged only on a release line is not on main' "$t/signals.txt" \
    || fail "$base_ref: ancestry requirement omitted"
done
echo 'ok main, fast pilot and unchanged release use exactly their enforced contexts and preserve ancestry requirements'

[[ ! -e "$t/danger" ]] || fail "forbidden action: $(cat "$t/danger")"
echo 'PIN WAIT PASS'
