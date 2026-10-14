#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pr-gate-audit.sh — score queued heads with the governed jankurai, on the gate host.
#
# The forge does not run jankurai. Each push to main or to an open pull request's head leaves one
# audit job on the forge (branch, head, base, mode), and `jankurai/proof` completes only from a report
# that comes back through the authenticated ingest and matches that job. This claims jobs as the gate
# identity, audits each head itself in a throwaway clone with the host's governed jankurai, and
# submits the report. It is the only producer of those reports: a recipe's own audit file is written
# by the head under test, so it is never what gets submitted.
#
# One pass, one claim batch (PR_GATE_AUDIT_MAX, default 1, at most 8), from pr-gate-audit.timer;
# never two passes at once on one host. Each audit is niced, idle-I/O and time-boxed, because the
# gate slots share the machine. It never takes a gate lock, posts a status or touches a gate's tree.
#
# The auditor is the one jankurai the host's installer verifies: pr-gate-ensure-jankurai.sh (the
# repository's generated verifier, installed beside this script) checks the binary at its governed
# install path, its installation receipt and the host's authority stamp, and names the version,
# sha256 and receipt the submission states. A host whose auditor does not verify audits nothing.
#
# Only reviewed code is checked out here. A job for main, or for the head of an open pull request the
# forge marks origin:internal (PR_GATE_INTERNAL_LABEL), is audited; a contribution (origin:contributed),
# a head no open pull request holds, or a forge that cannot say, is left alone -- this host checks out
# nothing of a contribution, exactly as the gate slots do not. A job left alone, like one whose clone
# failed, is not refused on the forge (it has no route for that): its claim lapses with its lease.
#
# Each pass beats once as "<short host>/jankurai-audit" (label jankurai-audit) so /runners shows the
# auditor beside the slots: `current` while an audit runs (kept alive every 60s; an audit can outlast
# the forge's offline threshold), `last` when it ends — scored (the forge recorded the report),
# tool-failed (the auditor wrote no usable report), refused (the forge refused the submission) or
# failed (the head could not be fetched; nothing ran). An idle pass re-sends the previous `last`.
#
# On wherever pr-gate-audit.timer is installed (the installer enables it like every other managed
# timer); an operator who does not want this host to audit masks the timer. A forge without the audit
# routes (404/405) is not an error: the pass says so and ends.
#
# Tuning (PR_GATE_AUDIT_MAX, PR_GATE_AUDIT_TIMEOUT, PR_GATE_AUDIT_BEAT_EVERY)
# belongs on this unit (a drop-in Environment= line), not in pr-gate.env: every PR_GATE_* key in the
# site file is bound into each gate's inputs unless it is listed as host-local, so a key added there
# re-gates every open head.
# ---------------------------------------------------------------------------
set -euo pipefail
BIN_DIR="$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")"
# Site configuration (forge, credential, identity): see pr-gate-config.sh.
# shellcheck source=ops/pr-gate/bin/pr-gate-config.sh
source "$BIN_DIR/pr-gate-config.sh"
pr_gate_load_config

say() { printf '[gate-audit %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
not_configured() { say "$1 is not configured (set it in $PR_GATE_CONFIG_FILE)"; exit 2; }

# The credential is sent only to the configured forge: JERYU_BASE may restate it, never redirect it.
CANONICAL="${PR_GATE_FORGE_URL:-}"
CANONICAL="${CANONICAL%/}"
[[ -n "$CANONICAL" ]] || not_configured PR_GATE_FORGE_URL
BASE="${JERYU_BASE:-$CANONICAL}"
BASE="${BASE%/}"
[[ "$BASE" == "$CANONICAL" ]] || { say "refusing a noncanonical credential origin"; exit 2; }
[[ "$BASE" =~ ^https?://[^[:space:]\"\']+$ ]] || { say "PR_GATE_FORGE_URL must be an http(s) URL"; exit 2; }
TOKEN_FILE="$(pr_gate_path "${JERYU_TOKEN_FILE:-}")"
[[ -n "$TOKEN_FILE" ]] || not_configured JERYU_TOKEN_FILE
IDENTITY="${GATE_RUNNER_IDENTITY:-}"
[[ -n "$IDENTITY" ]] || not_configured GATE_RUNNER_IDENTITY
[[ "$IDENTITY" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { say "GATE_RUNNER_IDENTITY is not a login"; exit 2; }
HOME_DIR="${GATE_RUNNER_HOME:-$HOME/gate-runner}"
MAX="${PR_GATE_AUDIT_MAX:-1}"
[[ "$MAX" =~ ^[1-8]$ ]] || { say "PR_GATE_AUDIT_MAX must be 1..8"; exit 2; }
AUDIT_TIMEOUT="${PR_GATE_AUDIT_TIMEOUT:-900}"
[[ "$AUDIT_TIMEOUT" =~ ^[1-9][0-9]{0,4}$ ]] || { say "PR_GATE_AUDIT_TIMEOUT must be seconds"; exit 2; }
# A pass must end inside the unit's TimeoutStartSec (10h): every job's audit plus its clone and submit.
((MAX * (AUDIT_TIMEOUT + 300) <= 36000)) \
  || { say "PR_GATE_AUDIT_MAX x (PR_GATE_AUDIT_TIMEOUT + 300s) exceeds the unit's 10h limit"; exit 2; }
BEAT_EVERY="${PR_GATE_AUDIT_BEAT_EVERY:-60}"
[[ "$BEAT_EVERY" =~ ^[1-9][0-9]*$ ]] || BEAT_EVERY=60
HOST="$(hostname -s)"
[[ "$HOST" =~ ^[A-Za-z0-9.-]{1,64}$ ]] || { say "this host's short name is not usable as a runner id"; exit 2; }
RUNNER_ID="$HOST/jankurai-audit"
LAST_FILE="$HOME_DIR/cache/audit-last.json"
# The repositories this host serves, exactly as the slots and the wake timer choose them: an explicit
# GATE_RUNNER_REPOS list (owner/repo), else every repository of GATE_RUNNER_OWNERS. A job for any other
# repository is left alone.
REPOS="${GATE_RUNNER_REPOS:-auto}"
OWNERS="${GATE_RUNNER_OWNERS:-}"
[[ "$REPOS" != auto || -n "${OWNERS// }" ]] || not_configured "GATE_RUNNER_OWNERS (or GATE_RUNNER_REPOS)"
INTERNAL_LABEL="${PR_GATE_INTERNAL_LABEL:-origin:internal}"
CONTRIBUTED_LABEL="${PR_GATE_CONTRIBUTED_LABEL:-origin:contributed}"
for tool in curl jq git sha256sum timeout flock; do command -v "$tool" >/dev/null || { say "$tool is required"; exit 2; }; done

[[ -f "$TOKEN_FILE" && ! -L "$TOKEN_FILE" && "$(stat -c '%a' "$TOKEN_FILE")" == 600 ]] \
  || { say "the credential must be a regular mode-0600 file"; exit 2; }

mkdir -p "$HOME_DIR/cache"
exec 9>"$HOME_DIR/.audit.lock"
flock -n 9 || { say "another audit pass is running"; exit 0; }
# shellcheck source=ops/pr-gate/bin/pr-gate-backoff.sh
source "$BIN_DIR/pr-gate-backoff.sh"
# gate_runner_code: what this host runs, for the heartbeat. Optional.
# shellcheck source=ops/pr-gate/bin/pr-gate-state.sh
source "$BIN_DIR/pr-gate-state.sh" 2>/dev/null || true

# The governed auditor. The verifier exits nonzero, naming why, when the install does not verify.
# Nothing ambient may widen what it accepts: the site file back-fills JERYU_* keys, and the verifier
# reads switches that admit a test receipt, a caller-named receipt or authority, or a release broker.
unset JERYU_JANKURAI_ALLOW_TEST_RECEIPT JERYU_JANKURAI_RECEIPT JERYU_JANKURAI_RECEIPT_SHA256 \
  JERYU_JANKURAI_AUTHORITY_SHA256 JERYU_GOVERNED_JANKURAI_BIN JAIN_RELEASE_CI
# A host without a verifying auditor is a configuration state, not a failure every 30 seconds: the
# pass says why once per run and claims nothing. The verifier exits on refusal, so it is tried in a
# subshell first.
VERIFIER="$BIN_DIR/pr-gate-ensure-jankurai.sh"
[[ -f "$VERIFIER" ]] || { say "$VERIFIER is not installed; nothing audited"; exit 0; }
# shellcheck source=ops/ci/ensure-jankurai.sh
if ! why="$( ( source "$VERIFIER" ) 2>&1 >/dev/null )"; then
  say "the governed jankurai does not verify on this host (${why:0:300}); nothing audited"; exit 0
fi
# shellcheck source=ops/ci/ensure-jankurai.sh
source "$VERIFIER" >/dev/null
for var in JERYU_GOVERNED_JANKURAI_BIN JERYU_JANKURAI_VERSION JERYU_JANKURAI_SHA256 JERYU_JANKURAI_SEMVER; do
  [[ -n "${!var:-}" ]] || { say "the verifier did not name $var; nothing audited"; exit 0; }
done

# Clones live under the gate home (disk), never a shared tmpfs; a crashed pass's leftovers are swept
# here, under the pass lock.
mkdir -p "$HOME_DIR/audit-work"
find "$HOME_DIR/audit-work" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
WORK_DIR="$(mktemp -d "$HOME_DIR/audit-work/pass.XXXXXX")"
keepalive=""
stop_keepalive() {
  [[ -n "$keepalive" ]] || return 0
  pkill -P "$keepalive" 2>/dev/null || true
  kill "$keepalive" 2>/dev/null || true
  wait "$keepalive" 2>/dev/null || true
  keepalive=""
}
trap 'stop_keepalive; rm -rf -- "$WORK_DIR"' EXIT
# The token reaches curl through a 0600 config file and git through a credential helper that reads
# the token file when git asks, so it is in no argv, environment or clone config.
AUTH_CONFIG="$WORK_DIR/curl-auth.conf"
( umask 077
  token="$(cat "$TOKEN_FILE")"
  [[ "$token" =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || { say "the credential has an invalid bearer-token shape"; exit 2; }
  printf 'header = "Authorization: Bearer %s"\n' "$token" >"$AUTH_CONFIG" )
# shellcheck disable=SC2016  # expanded by git's helper shell, not here
GIT_HELPER='!f() { [ "$3" = get ] || exit 0; printf "username=%s\npassword=%s\n" "$1" "$(cat "$2")"; }; f'
# Every git command of the pass runs with this environment -- the checkout most of all, since it is the
# one that writes the head's files: no LFS smudge (a head's .lfsconfig could name any URL), no prompt,
# and no global or system configuration (filters, hooks paths, URL rewrites) beyond the credential.
git_auth=(env GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  GIT_CONFIG_COUNT=2
  GIT_CONFIG_KEY_0="credential.$BASE/git/.helper" GIT_CONFIG_VALUE_0=""
  GIT_CONFIG_KEY_1="credential.$BASE/git/.helper" GIT_CONFIG_VALUE_1="$GIT_HELPER '$IDENTITY' '$TOKEN_FILE'")

# api METHOD PATH [BODY-FILE]: sets $code and $body. A 429 widens the host's shared back-off.
api() {
  local hdr out args=(--disable --silent --show-error --max-time 60 -X "$1" --config "$AUTH_CONFIG"
    -H 'Accept: application/json')
  [[ -z "${3:-}" ]] || args+=(-H 'Content-Type: application/json' --data-binary "@$3")
  hdr="$WORK_DIR/headers"
  out="$(curl "${args[@]}" --dump-header "$hdr" -w '\n%{http_code}' "$BASE$2")" || out=$'\n000'
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  if [[ "$code" == 429 ]]; then backoff_note_429 "$hdr"; elif [[ "$code" =~ ^2 ]]; then backoff_clear; fi
}

# --- heartbeat (best effort: a beat never fails the pass) ---------------------------------------
beat_code="$(declare -F gate_runner_code >/dev/null && gate_runner_code "$HOME_DIR" || true)"
beat_tools="$(jq -cn --arg v "$JERYU_JANKURAI_SEMVER" --arg s "$JERYU_JANKURAI_SHA256" \
  '[{name: "jankurai", version: $v, sha256: $s}]')"
beat_current=null
beat_last() { jq -ce 'select(type == "object" and (.conclusion | type) == "string")' "$LAST_FILE" 2>/dev/null || echo null; }
beat() {
  local body status
  body="$(jq -cn --arg id "$RUNNER_ID" --arg host "$HOST" --argjson current "$beat_current" \
    --argjson last "$(beat_last)" --arg code "${beat_code:-}" --argjson tools "$beat_tools" \
    --argjson every "$BEAT_EVERY" '
    {runnerId: $id, host: $host, slot: 0, labels: ["jankurai-audit"], intervalSeconds: $every}
    + (if $current != null then {current: $current} else {} end)
    + (if $last != null then {last: $last} else {} end)
    + (if $code != "" then {code: ($code | fromjson)} else {} end)
    + {tools: $tools}')" || return 0
  # An older forge refuses the whole beat (422) for a field it does not know: it is retried without
  # tools, then without code too, then in the oldest shape the slots' own heartbeat sends.
  local shape
  for shape in . 'del(.tools)' 'del(.tools, .code)' 'del(.tools, .code, .intervalSeconds)'; do
    status="$(jq -c "$shape" <<<"$body" | curl --disable --config "$AUTH_CONFIG" --silent --max-time 5 \
      -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @- \
      "$BASE/api/v1/runners/heartbeat" 2>/dev/null)" || status=000
    [[ "$status" == 422 ]] || break
  done
  [[ "$status" =~ ^2 ]] || say "heartbeat not accepted (HTTP $status; ignored)"
  return 0
}
beat_start() { # repo sha
  beat_current="$(jq -cn --arg repo "$1" --arg sha "$2" --arg at "$(date -u +%FT%TZ)" \
    '{repo: $repo, sha: $sha, recipe: "jankurai audit", startedAt: $at}')"
  beat
  # Without the pass lock (fd 9): a lingering sleep must not hold it after the pass ends.
  ( trap - EXIT; while sleep "$BEAT_EVERY"; do beat; done ) >/dev/null 2>&1 9>&- &
  keepalive=$!
}
beat_finish() { # repo sha conclusion seconds [reason]
  stop_keepalive
  beat_current=null
  jq -cn --arg repo "$1" --arg sha "$2" --arg conclusion "$3" --argjson seconds "$4" --arg reason "${5:-}" \
    --arg at "$(date -u +%FT%TZ)" '
    {repo: $repo, sha: $sha, recipe: "jankurai audit", conclusion: $conclusion, seconds: $seconds, finishedAt: $at}
    + (if $reason != "" then {reason: $reason} else {} end)' >"$LAST_FILE.tmp.$$" \
    && mv -f -- "$LAST_FILE.tmp.$$" "$LAST_FILE" || true
  beat
}

# --- claim ---------------------------------------------------------------------------------------
if (($(backoff_remaining) > 0)); then say "the forge asked this host to back off; nothing claimed"; exit 0; fi
jq -cn --arg id "$RUNNER_ID" --argjson max "$MAX" '{runner_id: $id, max: $max}' >"$WORK_DIR/claim.json"
api POST /api/v1/jankurai-audits/claim "$WORK_DIR/claim.json"
case "$code" in
  2??) ;;
  404|405) say "the forge has no audit queue (HTTP $code); nothing to do"; exit 0;;
  429) say "rate-limited; backing off"; exit 0;;
  *) say "claim refused (HTTP $code): ${body:0:300}"; beat; exit 0;;
esac
# Fields are split on the unit separator, not a tab: tab is IFS whitespace, so `read` would collapse an
# empty field (a full job's base) and shift every later one.
mapfile -t jobs < <(jq -r '.tickets[]? | [.owner, .repo, .branch, .headSha, (.baseSha // ""), (.auditMode // "diff")]
  | map(tostring | gsub("[\u0000-\u001f]"; "")) | join("\u001f")' <<<"$body" 2>/dev/null || true)
if ((${#jobs[@]} == 0)); then say "no audit work claimed"; beat; exit 0; fi

# --- audit and submit one job ---------------------------------------------------------------------
# The policy the auditor scores by never comes from the head under test: a head could lower its own
# floor or exclude its own changes. A diff job uses the base commit's agent/audit-policy.toml (already
# reviewed into the branch the head merges into); a full job, or a base without a regular policy
# file, uses the default below. Its floor is the forge's own (85), its version the verified auditor's.
default_policy() {
  printf '%s\n' 'schema_version = "1.0.0"' 'workspace = "unconfigured"' 'minimum_score = 85' \
    'hard_findings_allowed = 0' 'required_tool = "jankurai"' \
    "required_tool_version = \"$JERYU_JANKURAI_SEMVER\""
}

# prepare_tree SRC BASE MODE: make the checked-out head safe to audit and give it trusted metadata.
#
# What the auditor reads besides the code -- agent/ (policy, generated zones, boundaries, test and owner
# maps) and .jeryu/ (the CI declaration) -- comes from the base commit for a diff job, so a head can
# neither lower its floor nor mark its own files generated or excluded; a full job (no base) keeps the
# head's metadata but always the default policy. Then every symlink resolving outside the clone is
# removed, so the auditor can neither read a host file through the tree nor write through one, and the
# paths it writes to (.jankurai, target) are real directories. Finally every tracked path this changed
# is marked assume-unchanged: diff-audit scores the worktree against the base, and must see only what
# the head committed, never these edits. Fails (nonzero) rather than audit a tree it could not make safe.
prepare_tree() {
  local src=$1 base=$2 mode=$3 root link target entry dir
  root="$(realpath -- "$src")" || return 1
  if [[ "$mode" == diff ]]; then
    for dir in agent .jeryu; do
      rm -rf -- "${root:?}/$dir" || return 1
      if [[ -n "$("${git_auth[@]}" git -C "$root" ls-tree "$base" -- "$dir")" ]]; then
        "${git_auth[@]}" git -C "$root" archive --format=tar "$base" -- "$dir" | tar -x -C "$root" || return 1
      fi
    done
  fi
  while IFS= read -r -d '' link; do
    target="$(realpath -m -- "$link")" || target=""
    [[ "$target" == "$root" || "$target" == "$root"/* ]] || rm -f -- "$link" || return 1
  done < <(find "$root" -path "$root/.git" -prune -o -type l -print0)
  for entry in .jankurai target agent; do
    if [[ -L "$root/$entry" || ( -e "$root/$entry" && ! -d "$root/$entry" ) ]]; then rm -f -- "$root/$entry" || return 1; fi
    mkdir -p -- "$root/$entry" || return 1
  done
  if [[ "$mode" == diff && -f "$root/agent/audit-policy.toml" && ! -L "$root/agent/audit-policy.toml" ]]; then
    cp -- "$root/agent/audit-policy.toml" "$WORK_DIR/policy.toml"
    policy_source="base $base"
  else
    rm -rf -- "$root/agent/audit-policy.toml" || return 1
    default_policy >"$WORK_DIR/policy.toml"
    cp -- "$WORK_DIR/policy.toml" "$root/agent/audit-policy.toml"
    policy_source=default
  fi
  # Hide this function's own edits from the diff: modified and deleted tracked paths keep the head's
  # index entry. New files are untracked and never enter the diff set.
  "${git_auth[@]}" git -C "$root" ls-files -z -m -d | sort -zu \
    | xargs -0 -r "${git_auth[@]}" git -C "$root" update-index --assume-unchanged -- || return 1
}

# admission OWNER REPO BRANCH HEAD: nothing when the head is reviewed code this host may check out;
# else why not. main is reviewed by protection. Any other head must be held by an open pull request
# the forge marks internal (jeryu's own rows label every pull request internal or contributed, set by
# the importer, never by the author); anything the forge cannot vouch for is refused.
admission() {
  local owner=$1 repo=$2 branch=$3 head=$4 row="" page more
  if [[ "$REPOS" != auto ]]; then
    pr_gate_listed "$REPOS" "$owner/$repo" || { printf '%s/%s is not one of the repositories this host serves' "$owner" "$repo"; return; }
  else
    pr_gate_listed "$OWNERS" "$owner" || { printf '%s is not an owner this host serves' "$owner"; return; }
  fi
  # main is checked after the clone, against the clone's own main (the ticket's word is not enough).
  [[ "$branch" != main ]] || return 0
  for ((page = 1; page <= 20; page++)); do
    api GET "/api/v1/repos/$owner%2F$repo/pulls?state=open&per_page=500&page=$page"
    [[ "$code" == 200 ]] || { printf 'the forge answered %s listing its pull requests' "$code"; return; }
    row="$(jq -c --arg h "$head" 'first(.items[]? | select(.head_sha == $h)) // empty' <<<"$body" 2>/dev/null)"
    more="$(jq -r '.page.has_more // false' <<<"$body" 2>/dev/null)"
    [[ -z "$row" && "$more" == true ]] || break
  done
  [[ -n "$row" ]] || { printf 'no open pull request holds this head'; return; }
  # A label is a string or a {name} object, on the row or under its summary (as the slots read it).
  label_on() { jq -e --arg name "$2" 'any((.labels // .summary.labels // [])[]?; (if type == "string" then . else (.name // "") end) == $name)' <<<"$1" >/dev/null 2>&1; }
  if label_on "$row" "$CONTRIBUTED_LABEL"; then
    printf 'a contribution (%s): the gate host checks out nothing of it' "$CONTRIBUTED_LABEL"; return
  fi
  label_on "$row" "$INTERNAL_LABEL" || printf 'its pull request is not marked %s' "$INTERNAL_LABEL"
}

audit_one() { # owner repo branch head base mode
  local owner=$1 repo=$2 branch=$3 head=$4 base=$5 mode=$6 started=$SECONDS
  local src="$WORK_DIR/src" out="$WORK_DIR/report.json" request="$WORK_DIR/request.json" exit_code=0
  policy_source=""
  # A full job is the one with no commit base: its base may be empty or a marker, never handed to the
  # auditor. A diff job needs a real one.
  if ! [[ "$owner" =~ ^[A-Za-z0-9._-]{1,100}$ && "$repo" =~ ^[A-Za-z0-9._-]{1,100}$ && "$owner$repo" != *..* &&
          "$head" =~ ^[0-9a-f]{40}$ && "$mode" =~ ^(diff|full)$ && "$branch" =~ ^[A-Za-z0-9._/-]{1,255}$ &&
          ( "$base" =~ ^[0-9a-f]{40}$ || ( "$mode" == full && -z "$base" ) ) ]]; then
    say "skipping a malformed ticket: ${owner:0:100}/${repo:0:100}@${head:0:40}"
    return 0
  fi
  local refusal
  refusal="$(admission "$owner" "$repo" "$branch" "$head")"
  if [[ -n "$refusal" ]]; then
    say "not auditing $owner/$repo@$head here: $refusal"
    return 0
  fi
  say "$owner/$repo@$head ($branch, $([[ $mode == full ]] && echo "whole tree" || echo "vs $base"))"
  beat_start "$owner/$repo" "$head"
  rm -rf -- "$src" "$out"
  if ! "${git_auth[@]}" git clone -q --no-checkout "$BASE/git/$owner/$repo.git" "$src" 2>&1; then
    beat_finish "$owner/$repo" "$head" failed "$((SECONDS - started))" "clone failed"; return 0
  fi
  # A head the branch no longer points at (or one only a pull request ref holds) is fetched by ref.
  if ! "${git_auth[@]}" git -C "$src" cat-file -e "$head^{commit}" 2>/dev/null; then
    "${git_auth[@]}" git -C "$src" fetch -q origin '+refs/pull/*/head:refs/remotes/origin/pull/*' 2>&1 || true
  fi
  # main is admitted only when the head really is main's: reachable from the clone's own main.
  if [[ "$branch" == main ]] && ! "${git_auth[@]}" git -C "$src" merge-base --is-ancestor "$head" refs/remotes/origin/main 2>/dev/null; then
    say "not auditing $owner/$repo@$head here: the ticket says main, but the head is not on main"
    beat_finish "$owner/$repo" "$head" failed "$((SECONDS - started))" "the head is not on main"; return 0
  fi
  if ! "${git_auth[@]}" git -C "$src" -c advice.detachedHead=false checkout -q --detach "$head" 2>&1; then
    beat_finish "$owner/$repo" "$head" failed "$((SECONDS - started))" "head is not in the clone"; return 0
  fi
  if ! prepare_tree "$src" "$base" "$mode"; then
    beat_finish "$owner/$repo" "$head" failed "$((SECONDS - started))" "the tree could not be made safe to audit"; return 0
  fi
  # The invocations are the family's own: a full job as ops/ci/score.sh audits a whole tree (advisory
  # mode, so the forge, not the tool, decides), a diff job exactly as ops/ci/jankurai-gate.sh renders
  # the host's (skipping the proof plan when there is no owner map to prove lanes against).
  local -a args
  if [[ "$mode" == full ]]; then
    args=(audit . --full --mode advisory --policy "$WORK_DIR/policy.toml" --json "$out" --no-score-history)
  else
    args=(diff-audit "$src" --base-ref "$base" --json "$out" --advisory-only)
    [[ -f "$src/agent/owner-map.json" ]] || args+=(--skip-proof)
  fi
  ( cd "$src" && timeout "$AUDIT_TIMEOUT" nice -n 10 ionice -c 3 "$JERYU_GOVERNED_JANKURAI_BIN" "${args[@]}" ) \
    >"$WORK_DIR/audit.log" 2>&1 || exit_code=$?
  # The auditor's output can quote the head; only a bounded, printable tail reaches the journal.
  tail -n 3 "$WORK_DIR/audit.log" | LC_ALL=C tr -cd '[:print:]\n' | cut -c1-200 | sed 's/^/  /' || true

  local conclusion=scored reason=""
  ((exit_code == 0)) || { conclusion="tool-failed"; reason="jankurai exited $exit_code"; }
  # The report names the policy it was scored by, so a reader comparing it with a local run of the
  # head's own policy can see why they differ.
  if jq -e 'type == "object"' "$out" >/dev/null 2>&1; then
    jq --arg source "$policy_source" --arg sha "$(sha256sum "$WORK_DIR/policy.toml" | cut -d' ' -f1)" \
      '. + {jeryu_audit_policy: {source: $source, sha256: $sha}}' "$out" >"$out.tmp" && mv -f -- "$out.tmp" "$out"
  else
    printf 'null\n' >"$out"
  fi
  jq -n --arg branch "$branch" --arg head "$head" --arg base "$base" --arg runner "$RUNNER_ID" \
    --arg version "$JERYU_JANKURAI_VERSION" --arg sha "$JERYU_JANKURAI_SHA256" \
    --arg receipt "${JERYU_JANKURAI_RECEIPT_SHA256:-}" --arg mode "$mode" --argjson exit "$exit_code" \
    --slurpfile report "$out" '
    {branch: $branch, commit_sha: $head, base_sha: $base, runner_id: $runner,
     jankurai_version: $version, jankurai_sha256: $sha, audit_mode: $mode, tool_exit: $exit,
     report: $report[0]}
    + (if ($receipt | test("^[0-9a-f]{64}$")) then {jankurai_receipt_sha256: $receipt} else {} end)' >"$request"
  api POST "/api/v1/repos/$owner%2F$repo/jankurai-scores" "$request"
  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    say "$owner/$repo@$head scored $(jq -r '.score // "?"' <<<"$body" 2>/dev/null || echo "?") ($mode audit, $JERYU_JANKURAI_VERSION, policy: $policy_source)"
  else
    say "$owner/$repo@$head report refused (HTTP $code): ${body:0:300}"
    conclusion=refused reason="the forge refused the report (HTTP $code)"
  fi
  beat_finish "$owner/$repo" "$head" "$conclusion" "$((SECONDS - started))" "$reason"
  rm -rf -- "$src"
}

# One job's failure is that job's: whatever a head does to its own audit, the pass goes on, the claim
# is reported finished, and the next job runs. Each job runs in its own subshell, started in the
# background and waited for, so `set -e` stays in force inside it (a subshell tested by `if` would
# run with it silently off) and its keepalive dies with it.
for job in "${jobs[@]}"; do
  IFS=$'\x1f' read -r owner repo branch head base mode <<<"$job"
  ( trap stop_keepalive EXIT; audit_one "$owner" "$repo" "$branch" "$head" "$base" "$mode" ) &
  if ! wait "$!"; then
    beat_finish "$owner/$repo" "$head" failed 0 "the audit stopped unexpectedly"
  fi
done
