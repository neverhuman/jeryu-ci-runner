#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pr-gate-audit.sh — score queued heads with the governed jankurai, on the gate host.
#
# The forge does not run jankurai. Each push to main or to an open pull request's head leaves one
# audit job on the forge (branch, head, base, mode), and `jankurai/proof` completes only from a report
# that comes back through the authenticated ingest and matches that job. This claims jobs as the gate
# identity, audits each head itself in a throwaway clone with a governed jankurai, and submits the
# report. It is the only producer of those reports: a recipe's own audit file is written by the head
# under test, so it is never what gets submitted.
#
# One pass, one claim batch (PR_GATE_AUDIT_MAX, default 1, at most 8), from pr-gate-audit.timer;
# never two passes at once on one host. Each audit is niced, idle-I/O and time-boxed, because the
# gate slots share the machine. It never takes a gate lock, posts a status or touches a gate's tree.
#
# Two contracts, chosen per pass by what the forge says it serves (GET /api/v1/capabilities):
#
#   bound (jankurai_audit_jobs.binding >= 1; jeryu-deploy ADR 0011 as superseded by 0012): every job names its auditor -- version,
#   target, binary and signer digests, from the forge's approved-manifest snapshot -- plus the commit
#   its metadata comes from and its policy digest. The claim lists the auditors this host has staged
#   and verified (<tools>/jankurai/<binary sha256>/{bin/jankurai,receipt.json}, PR_GATE_AUDIT_TOOLS),
#   so only jobs it can run come back. Each job's auditor is checked against its installation
#   receipt before checkout and again right before it runs; no release-specific verifier is involved.
#   A job this host will not run is handed back at once with a reason
#   (POST /api/v1/jankurai-audits/:job_id/release), never left to lapse. The submission echoes the
#   binding, and the forge refuses any report that differs from it.
#
#   unbound (any older forge): the host's one governed jankurai, verified by the repository's
#   generated verifier installed beside this script (pr-gate-ensure-jankurai.sh). A job left alone
#   lapses with its lease.
#
# Bound tickets admit every served head regardless of pushing clone. Contributions require the
# site's sandbox command; unbound tickets retain the internal-PR admission contract.
#
# Each pass beats once as "<short host>/jankurai-audit" (label jankurai-audit) so /runners shows the
# auditor beside the slots: `current` while an audit runs (state running, then publishing; kept alive
# every 60s), `last` when it ends -- scored, qualified (a candidate's qualification run was recorded),
# tool-failed (the auditor wrote no usable report), released (handed back, with the reason), refused
# or rejected-publication (the forge refused the submission), failed (the head could not be fetched).
#
# On wherever pr-gate-audit.timer is installed (the installer enables it like every other managed
# timer); an operator who does not want this host to audit masks the timer. A forge without the audit
# routes (404/405) is not an error: the pass says so and ends.
#
# Tuning (PR_GATE_AUDIT_MAX, PR_GATE_AUDIT_TIMEOUT, PR_GATE_AUDIT_BEAT_EVERY, PR_GATE_AUDIT_TOOLS)
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
# Where the host's tool installer stages every approved auditor by digest (bound contract only).
TOOLS_ROOT="$(pr_gate_path "${PR_GATE_AUDIT_TOOLS:-~/.jeryu/tools}")"
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
# Reuse the gate recipe sandbox contract: command tree-root repo recipe... .
SANDBOX_COMMAND="${PR_GATE_SANDBOX_COMMAND:-}"
SANDBOX_PATH="${PR_GATE_SANDBOX_PATH:-/usr/local/bin:/usr/bin:/bin}"
sandbox_ready=false
sandbox_cmd=()
read -r -a sandbox_cmd <<<"$SANDBOX_COMMAND"
if ((${#sandbox_cmd[@]})); then
  sandbox_executable="$(PATH="$SANDBOX_PATH" command -v "${sandbox_cmd[0]}" || true)"
  if [[ "$sandbox_executable" == /* && -f "$sandbox_executable" && -x "$sandbox_executable" ]]; then
    sandbox_cmd[0]=$sandbox_executable
    sandbox_ready=true
  fi
fi
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
# The token reaches curl through a 0600 config file and git through a credential helper that reads
# the token file when git asks, so it is in no argv, environment or clone config. The config lives in
# the gate's cache, never beside the clone a head is unpacked into.
AUTH_CONFIG="$(mktemp "$HOME_DIR/cache/audit-auth.XXXXXX")"
trap 'stop_keepalive; rm -rf -- "$WORK_DIR"; rm -f -- "$AUTH_CONFIG"' EXIT
chmod 0600 "$AUTH_CONFIG"
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
# The auditor runs git inside the head's tree too: the same hardening, without any credential.
audit_env=(env GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  GIT_CONFIG_COUNT=0)

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
# Forge-supplied text that reaches the journal or /runners: printable and bounded.
clean() { LC_ALL=C tr -cd '[:print:]' <<<"${1:0:${2:-300}}"; }

# --- heartbeat (best effort: a beat never fails the pass) ---------------------------------------
beat_code="$(declare -F gate_runner_code >/dev/null && gate_runner_code "$HOME_DIR" || true)"
beat_tools='[]'  # filled in once the auditor(s) this host can run are verified
beat_current=null
BOUND=0
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
    + (if ($tools | length) > 0 then {tools: $tools} else {} end)')" || return 0
  # An older forge refuses the whole beat (422) for a field it does not know: it is retried without
  # the runner state, then without tools, then without code too, then in the oldest shape the slots'
  # own heartbeat sends.
  local shape
  for shape in . 'del(.current.state)' 'del(.current.state, .tools)' 'del(.current.state, .tools, .code)' \
      'del(.current.state, .tools, .code, .intervalSeconds)' 'del(.current.state, .tools, .code, .intervalSeconds, .last)'; do
    status="$(jq -c "$shape" <<<"$body" | curl --disable --config "$AUTH_CONFIG" --silent --max-time 5 \
      -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @- \
      "$BASE/api/v1/runners/heartbeat" 2>/dev/null)" || status=000
    [[ "$status" == 422 ]] || break
  done
  [[ "$status" =~ ^2 ]] || say "heartbeat not accepted (HTTP $status; ignored)"
  return 0
}
beat_start() { # repo sha
  beat_current="$(jq -cn --arg repo "$1" --arg sha "$2" --arg at "$(date -u +%FT%TZ)" --argjson bound "$BOUND" '
    {repo: $repo, sha: $sha, recipe: "jankurai audit", startedAt: $at}
    + (if $bound == 1 then {state: "running"} else {} end)')"
  beat
  # Without the pass lock (fd 9): a lingering sleep must not hold it after the pass ends.
  ( trap - EXIT; while sleep "$BEAT_EVERY"; do beat; done ) >/dev/null 2>&1 9>&- &
  keepalive=$!
}
beat_state() { # state -- the running audit's current state (bound contract only)
  ((BOUND)) && [[ "$beat_current" != null ]] || return 0
  beat_current="$(jq -c --arg s "$1" '.state = $s' <<<"$beat_current")"
  beat
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
# A refusal of the whole pass is reported where operators look (/runners), not only in the journal.
no_auditor() { # reason
  say "$1; nothing audited"
  jq -cn --arg reason "$1" --arg at "$(date -u +%FT%TZ)" \
    '{recipe: "jankurai audit", conclusion: "failed", seconds: 0, finishedAt: $at, reason: $reason}' \
    >"$LAST_FILE.tmp.$$" && mv -f -- "$LAST_FILE.tmp.$$" "$LAST_FILE" || true
  beat
  exit 0
}

# --- which contract the forge serves ------------------------------------------------------------
# Nothing ambient may widen what any verifier accepts: the site file back-fills JERYU_* keys, and the
# generated verifier reads switches that admit a test receipt, a caller-named receipt or authority, or a
# release broker.
unset JERYU_JANKURAI_ALLOW_TEST_RECEIPT JERYU_JANKURAI_RECEIPT JERYU_JANKURAI_RECEIPT_SHA256 \
  JERYU_JANKURAI_AUTHORITY_SHA256 JERYU_GOVERNED_JANKURAI_BIN JAIN_RELEASE_CI
api GET /api/v1/capabilities
if [[ "$code" == 200 ]]; then
  binding="$(jq -r '.jankurai_audit_jobs.binding // 0 | tostring' <<<"$body" 2>/dev/null || echo 0)"
  [[ "$binding" =~ ^[0-9]{1,4}$ ]] && ((binding >= 1)) && BOUND=1
fi

# verify_staged SHA [VERSION TARGET SIGNER]: the auditor staged under that digest, checked against its
# own installation receipt and, when given, the job's assigned identity. Prints the receipt's sha256;
# on refusal prints the release reason (staged-digest-missing or verifier-mismatch) and fails. The
# receipt's install-time manifest is deliberately not compared: one binary stays approved across
# manifest revisions, and the forge's snapshot, not the receipt, says which are approved now.
verify_staged() {
  local sha=$1 want_v=${2:-} want_t=${3:-} want_s=${4:-} dir bin rec
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo verifier-mismatch; return 1; }
  dir="$TOOLS_ROOT/jankurai/$sha" bin="$TOOLS_ROOT/jankurai/$sha/bin/jankurai" rec="$TOOLS_ROOT/jankurai/$sha/receipt.json"
  [[ -d "$dir" && ! -L "$dir" && -f "$bin" && ! -L "$bin" && -x "$bin" && -f "$rec" && ! -L "$rec" ]] \
    || { echo staged-digest-missing; return 1; }
  [[ "$(stat -c %h -- "$bin")" == 1 && "$(sha256sum <"$bin" | cut -c1-64)" == "$sha" ]] || { echo verifier-mismatch; return 1; }
  jq -e --arg sha "$sha" --arg v "$want_v" --arg t "$want_t" --arg s "$want_s" '
    (.schema | type == "string" and startswith("jeryu.jankurai-installation/v"))
    and .binary.sha256 == $sha and (.binary.version_output | type == "string")
    and .test_mode == false and .conclusion == "success" and .signature.verified == true
    and .governance.status == "governed"
    and ($v == "" or .binary.version_output == ("jankurai " + $v))
    and ($t == "" or .build.target_triple == $t)
    and ($s == "" or .signature.signer_sha256 == $s)' "$rec" >/dev/null 2>&1 || { echo verifier-mismatch; return 1; }
  [[ "$(cd / && timeout 10 "$bin" --version 2>/dev/null | head -n 1)" == "$(jq -r .binary.version_output "$rec")" ]] \
    || { echo verifier-mismatch; return 1; }
  sha256sum <"$rec" | cut -c1-64
}

STAGED=()
if ((BOUND)); then
  # Every auditor staged here that verifies on its own receipt is offered; the forge hands back only
  # jobs bound to one of them. No release-specific verifier is consulted.
  for d in "$TOOLS_ROOT"/jankurai/*/; do
    [[ -d "$d" ]] || continue
    s="$(basename "$d")"
    verify_staged "$s" >/dev/null 2>&1 && STAGED+=("$s")
  done
  ((${#STAGED[@]})) || no_auditor "no staged jankurai under $TOOLS_ROOT/jankurai verifies on its receipt"
  beat_tools="$(for s in "${STAGED[@]}"; do
      jq -c --arg s "$s" '{name: "jankurai", version: (.binary.version_output | sub("^jankurai "; "")), sha256: $s}' \
        "$TOOLS_ROOT/jankurai/$s/receipt.json"
    done | jq -cs '.[0:32]')"
else
  # A host without a verifying auditor is a configuration state, not a failure every 30 seconds: the
  # pass says why once per run and claims nothing. The verifier exits on refusal, so it is tried in a
  # subshell first.
  VERIFIER="$BIN_DIR/pr-gate-ensure-jankurai.sh"
  [[ -f "$VERIFIER" ]] || no_auditor "$VERIFIER is not installed"
  # shellcheck source=ops/ci/ensure-jankurai.sh
  if ! why="$( ( source "$VERIFIER" ) 2>&1 >/dev/null )"; then
    no_auditor "the governed jankurai does not verify on this host: $(clean "$why")"
  fi
  # shellcheck source=ops/ci/ensure-jankurai.sh
  source "$VERIFIER" >/dev/null
  for var in JERYU_GOVERNED_JANKURAI_BIN JERYU_JANKURAI_VERSION JERYU_JANKURAI_SHA256 JERYU_JANKURAI_SEMVER; do
    [[ -n "${!var:-}" ]] || no_auditor "the verifier did not name $var"
  done
  beat_tools="$(jq -cn --arg v "$JERYU_JANKURAI_SEMVER" --arg s "$JERYU_JANKURAI_SHA256" \
    '[{name: "jankurai", version: $v, sha256: $s}]')"
fi

# --- claim ---------------------------------------------------------------------------------------
if (($(backoff_remaining) > 0)); then say "the forge asked this host to back off; nothing claimed"; exit 0; fi
if ((BOUND)); then
  printf '%s\n' "${STAGED[@]}" | jq -R . | jq -cs --arg id "$RUNNER_ID" --argjson max "$MAX" --argjson sandbox "$sandbox_ready" \
    '{runner_id: $id, max: $max, capabilities: {jankurai: ., sandbox: $sandbox}}' >"$WORK_DIR/claim.json"
else
  jq -cn --arg id "$RUNNER_ID" --argjson max "$MAX" '{runner_id: $id, max: $max}' >"$WORK_DIR/claim.json"
fi
api POST /api/v1/jankurai-audits/claim "$WORK_DIR/claim.json"
case "$code" in
  2??) ;;
  404|405) say "the forge has no audit queue (HTTP $code); nothing to do"; exit 0;;
  429) say "rate-limited; backing off"; exit 0;;
  *) say "claim refused (HTTP $code): $(clean "$body")"; beat; exit 0;;
esac
# Each ticket becomes one compact JSON line with the same field names in both contracts.
if ((BOUND)); then
  mapfile -t jobs < <(jq -c '.tickets[]? | {owner, repo, branch, head: .head_sha, base: (.base_sha // ""),
    mode: (.audit_mode // "diff"), job_id, purpose: (.purpose // "proof"), origin, metadata_commit,
    policy_sha256, auditor}' <<<"$body" 2>/dev/null || true)
else
  mapfile -t jobs < <(jq -c '.tickets[]? | {owner, repo, branch, head: .headSha, base: (.baseSha // ""),
    mode: (.auditMode // "diff")}' <<<"$body" 2>/dev/null || true)
fi
if ((${#jobs[@]} == 0)); then say "no audit work claimed"; beat; exit 0; fi
# The pass's time budget is MAX jobs; a forge that hands out more gets the rest back when leases lapse.
((${#jobs[@]} <= MAX)) || { say "the forge handed out ${#jobs[@]} jobs for $MAX; auditing $MAX"; jobs=("${jobs[@]:0:MAX}"); }

# --- audit and submit one job ---------------------------------------------------------------------
# The policy the auditor scores by never comes from the head under test: a head could lower its own
# floor or exclude its own changes. The default stands in where the trusted commit has none. Its floor
# is the forge's own (85). Under the bound contract its bytes are fixed (ADR 0011) so its digest is
# stable across auditor releases; an unbound forge still gets the verified auditor's version in it.
default_policy() {
  printf '%s\n' 'schema_version = "1.0.0"' 'workspace = "unconfigured"' 'minimum_score = 85' \
    'hard_findings_allowed = 0' 'required_tool = "jankurai"'
  ((BOUND)) || printf 'required_tool_version = "%s"\n' "$JERYU_JANKURAI_SEMVER"
}

# policy_bytes ROOT COMMIT: the policy a job at COMMIT is scored by -- the commit's own regular
# agent/audit-policy.toml, else the default -- on stdout.
policy_bytes() {
  if [[ "$("${git_auth[@]}" git -C "$1" ls-tree "$2" -- agent/audit-policy.toml | cut -d' ' -f1)" == 100644 ]]; then
    "${git_auth[@]}" git -C "$1" show "$2:agent/audit-policy.toml"
  else
    default_policy
  fi
}

# choose_meta SRC BASE MODE BRANCH (unbound contract): sets meta and policy_source -- the job's base
# when main reaches it, the head itself when the job is main's (admission proved it is on main), else
# main's current tip; with no main at all, none.
choose_meta() {
  local root=$1 base=$2 mode=$3 branch=$4 main
  main="$("${git_auth[@]}" git -C "$root" rev-parse -q --verify 'refs/remotes/origin/main^{commit}' 2>/dev/null)" || main=""
  if [[ "$mode" == diff && -n "$main" ]] && "${git_auth[@]}" git -C "$root" merge-base --is-ancestor "$base" "$main" 2>/dev/null; then
    meta=$base; policy_source="base $base"
  elif [[ "$branch" == main ]]; then
    meta="$("${git_auth[@]}" git -C "$root" rev-parse HEAD)"; policy_source="main $meta"
  elif [[ -n "$main" ]]; then
    meta=$main; policy_source="main $main (the base is not on main)"
  else
    meta=none; policy_source=default
  fi
}

# prepare_tree SRC META: make the checked-out head safe to audit and give it trusted metadata.
#
# What the auditor reads besides the code -- agent/ (policy, generated zones, boundaries, test and owner
# maps) and .jeryu/ (the CI declaration) -- comes only from META, a commit main reaches (or none: the
# metadata is removed and the default policy used), so a head can neither lower its floor nor mark its
# own files generated or excluded. Then every symlink resolving outside the clone is removed, so the
# auditor can neither read a host file through the tree nor write through one, and the paths it writes
# to (.jankurai, target) are real directories. Finally every tracked path this changed is marked
# assume-unchanged: diff-audit scores the worktree against the base, and must see only what the head
# committed, never these edits. Fails (nonzero) rather than audit a tree it could not make safe.
prepare_tree() {
  local src=$1 meta=$2 root link target entry dir
  root="$(realpath -- "$src")" || return 1
  for dir in agent .jeryu; do
    rm -rf -- "${root:?}/$dir" || return 1
    if [[ "$meta" != none && -n "$("${git_auth[@]}" git -C "$root" ls-tree "$meta" -- "$dir")" ]]; then
      "${git_auth[@]}" git -C "$root" archive --format=tar "$meta" -- "$dir" | tar -x -C "$root" || return 1
    fi
  done
  while IFS= read -r -d '' link; do
    target="$(realpath -m -- "$link")" || target=""
    [[ "$target" == "$root" || "$target" == "$root"/* ]] || rm -f -- "$link" || return 1
  done < <(find "$root" -path "$root/.git" -prune -o -type l -print0)
  for entry in .jankurai target agent; do
    if [[ -L "$root/$entry" || ( -e "$root/$entry" && ! -d "$root/$entry" ) ]]; then rm -f -- "$root/$entry" || return 1; fi
    mkdir -p -- "$root/$entry" || return 1
  done
  rm -rf -- "$root/agent/audit-policy.toml" || return 1
  if [[ "$meta" == none ]]; then default_policy >"$WORK_DIR/policy.toml"; else policy_bytes "$root" "$meta" >"$WORK_DIR/policy.toml" || return 1; fi
  # The trusted commit had no policy of its own: say the default scored it, not the commit.
  [[ "$meta" != none && "$("${git_auth[@]}" git -C "$root" ls-tree "$meta" -- agent/audit-policy.toml | cut -d' ' -f1)" == 100644 ]] \
    || policy_source=default
  cp -- "$WORK_DIR/policy.toml" "$root/agent/audit-policy.toml"
  # Hide this function's own edits from the diff: modified and deleted tracked paths keep the head's
  # index entry. New files are untracked and never enter the diff set.
  "${git_auth[@]}" git -C "$root" ls-files -z -m -d | sort -zu \
    | xargs -0 -r "${git_auth[@]}" git -C "$root" update-index --assume-unchanged -- || return 1
}

# admission OWNER REPO BRANCH HEAD [ORIGIN]: nothing when this host can audit the ticket; else why not, as "<release reason>|<explanation>". main is reviewed by protection (checked after
# the clone, against the clone's own main). A bound job carries the forge's word on its origin; an
# unbound one must be held by an open pull request the forge marks internal (jeryu's own rows label
# every pull request internal or contributed, set by the importer, never by the author). Anything the
# forge cannot vouch for is refused.
admission() {
  local owner=$1 repo=$2 branch=$3 head=$4 origin=${5:-} row="" page more
  if [[ "$REPOS" != auto ]]; then
    pr_gate_listed "$REPOS" "$owner/$repo" \
      || { printf 'not-served-by-this-host|%s/%s is not one of the repositories this host serves' "$owner" "$repo"; return; }
  else
    pr_gate_listed "$OWNERS" "$owner" || { printf 'not-served-by-this-host|%s is not an owner this host serves' "$owner"; return; }
  fi
  if ((BOUND)); then
    [[ "$origin" == internal || "$sandbox_ready" == true ]] || printf 'contributed|a contribution (origin %s): the gate host checks out nothing of it' "${origin:-unknown}"
    return
  fi
  [[ "$branch" != main ]] || return 0
  for ((page = 1; page <= 20; page++)); do
    api GET "/api/v1/repos/$owner%2F$repo/pulls?state=open&per_page=500&page=$page"
    [[ "$code" == 200 ]] || { printf '|the forge answered %s listing its pull requests' "$code"; return; }
    row="$(jq -c --arg h "$head" 'first(.items[]? | select(.head_sha == $h)) // empty' <<<"$body" 2>/dev/null)"
    more="$(jq -r '.page.has_more // false' <<<"$body" 2>/dev/null)"
    [[ -z "$row" && "$more" == true ]] || break
  done
  [[ -n "$row" ]] || { printf '|no open pull request holds this head'; return; }
  # A label is a string or a {name} object, on the row or under its summary (as the slots read it).
  label_on() { jq -e --arg name "$2" 'any((.labels // .summary.labels // [])[]?; (if type == "string" then . else (.name // "") end) == $name)' <<<"$1" >/dev/null 2>&1; }
  if label_on "$row" "$CONTRIBUTED_LABEL"; then
    printf 'contributed|a contribution (%s): the gate host checks out nothing of it' "$CONTRIBUTED_LABEL"; return
  fi
  label_on "$row" "$INTERNAL_LABEL" || printf '|its pull request is not marked %s' "$INTERNAL_LABEL"
}

# release JOB-ID REASON: hand a bound job back to the forge at once, with its reason. A forge that
# does not answer is not fatal: the claim then lapses with its lease.
release() {
  jq -cn --arg r "$2" '{reason: $r}' >"$WORK_DIR/release.json"
  api POST "/api/v1/jankurai-audits/$1/release" "$WORK_DIR/release.json"
  [[ "$code" =~ ^2 ]] || say "the forge did not take job $1 back (HTTP $code); its claim lapses with its lease"
}

audit_one() { # ticket-json
  local t=$1 owner repo branch head base mode job="" purpose=proof origin="" mcommit="" psha="" auditor="null"
  local a_sha="" a_ver="" a_target="" a_signer="" receipt="" bin
  local started=$SECONDS src="$WORK_DIR/tree/src" out="$WORK_DIR/tree/report.json" request="$WORK_DIR/request.json" exit_code=0
  owner="$(jq -r '.owner // "" | tostring' <<<"$t")" repo="$(jq -r '.repo // "" | tostring' <<<"$t")"
  branch="$(jq -r '.branch // "" | tostring' <<<"$t")" head="$(jq -r '.head // "" | tostring' <<<"$t")"
  base="$(jq -r '.base // "" | tostring' <<<"$t")" mode="$(jq -r '.mode // "" | tostring' <<<"$t")"
  policy_source=""
  # A full job is the one with no commit base: its base may be empty or a marker, never handed to the
  # auditor. A diff job needs a real one.
  local valid=1
  [[ "$owner" =~ ^[A-Za-z0-9._-]{1,100}$ && "$repo" =~ ^[A-Za-z0-9._-]{1,100}$ && "$owner$repo" != *..* &&
     "$head" =~ ^[0-9a-f]{40}$ && "$mode" =~ ^(diff|full)$ && "$branch" =~ ^[A-Za-z0-9._/-]{1,255}$ &&
     ( "$base" =~ ^[0-9a-f]{40}$ || ( "$mode" == full && -z "$base" ) ) ]] || valid=0
  if ((BOUND)); then
    job="$(jq -r '.job_id // "" | tostring' <<<"$t")" purpose="$(jq -r '.purpose // "" | tostring' <<<"$t")"
    origin="$(jq -r '.origin // "" | tostring' <<<"$t")" mcommit="$(jq -r '.metadata_commit // "" | tostring' <<<"$t")"
    psha="$(jq -r '.policy_sha256 // "" | tostring' <<<"$t")" auditor="$(jq -c '.auditor // null' <<<"$t")"
    a_sha="$(jq -r '.binary_sha256 // "" | tostring' <<<"$auditor" 2>/dev/null || true)"
    a_ver="$(jq -r '.version // "" | tostring' <<<"$auditor" 2>/dev/null || true)"
    a_target="$(jq -r '.target // "" | tostring' <<<"$auditor" 2>/dev/null || true)"
    a_signer="$(jq -r '.signing_identity // "" | tostring' <<<"$auditor" 2>/dev/null || true)"
    [[ "$job" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || { say "skipping a ticket with no usable job id: $(clean "$owner/$repo@$head" 200)"; return 0; }
    [[ "$purpose" =~ ^(proof|qualification)$ && "$origin" =~ ^(internal|contributed)$ && "$mcommit" =~ ^[0-9a-f]{40}$ &&
       "$psha" =~ ^[0-9a-f]{64}$ && "$a_sha" =~ ^[0-9a-f]{64}$ && "$a_signer" =~ ^[0-9a-f]{64}$ &&
       "$a_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]{1,40})?$ && "$a_target" =~ ^[A-Za-z0-9._-]{1,80}$ &&
       "$(jq -r '.manifest_revision // ""' <<<"$auditor")" =~ ^[0-9a-f]{40}$ &&
       "$(jq -r '.manifest_sha256 // ""' <<<"$auditor")" =~ ^[0-9a-f]{64}$ ]] || valid=0
  fi
  # refuse REASON EXPLANATION [CONCLUSION]: this job is not audited here. A bound job is handed back
  # with its reason and reported released; an unbound one is reported (when it got that far) and lapses.
  refuse() {
    say "not auditing $owner/$repo@$head here: $2"
    if ((BOUND)) && [[ -n "$1" ]]; then
      release "$job" "$1"
      [[ "${3:-}" == quiet ]] || beat_finish "$owner/$repo" "$head" released "$((SECONDS - started))" "$1: $2"
    elif [[ -n "${3:-}" && "${3:-}" != quiet ]]; then
      beat_finish "$owner/$repo" "$head" "$3" "$((SECONDS - started))" "$2"
    fi
  }
  if ((!valid)); then
    say "skipping a malformed ticket: $(clean "$owner/$repo@$head" 200)"
    ((BOUND)) && release "$job" malformed-ticket
    return 0
  fi
  local refusal
  refusal="$(admission "$owner" "$repo" "$branch" "$head" "$origin")"
  if [[ -n "$refusal" ]]; then
    refuse "${refusal%%|*}" "${refusal#*|}" quiet
    return 0
  fi
  if ((BOUND)); then
    # The job's auditor must be staged here and match its assignment before anything is checked out.
    if ! receipt="$(verify_staged "$a_sha" "$a_ver" "$a_target" "$a_signer")"; then
      refuse "$receipt" "the assigned auditor jankurai $a_ver (${a_sha:0:12}) does not verify here"
      return 0
    fi
    bin="$TOOLS_ROOT/jankurai/$a_sha/bin/jankurai"
  else
    bin="$JERYU_GOVERNED_JANKURAI_BIN"
  fi
  say "$owner/$repo@$head ($branch, $([[ $mode == full ]] && echo "whole tree" || echo "vs $base")$( ((BOUND)) && echo ", job $job, $purpose, jankurai $a_ver"))"
  beat_start "$owner/$repo" "$head"
  rm -rf -- "$WORK_DIR/tree"
  mkdir -p "$WORK_DIR/tree"
  if ! "${git_auth[@]}" git clone -q --no-checkout "$BASE/git/$owner/$repo.git" "$src" 2>&1; then
    beat_finish "$owner/$repo" "$head" failed "$((SECONDS - started))" "clone failed"; return 0
  fi
  # A head the branch no longer points at (or one only a pull request ref holds) is fetched by ref.
  if ! "${git_auth[@]}" git -C "$src" cat-file -e "$head^{commit}" 2>/dev/null; then
    "${git_auth[@]}" git -C "$src" fetch -q origin '+refs/pull/*/head:refs/remotes/origin/pull/*' 2>&1 || true
  fi
  # main is admitted only when the head really is main's: reachable from the clone's own main.
  if [[ "$branch" == main ]] && ! "${git_auth[@]}" git -C "$src" merge-base --is-ancestor "$head" refs/remotes/origin/main 2>/dev/null; then
    refuse not-on-main "the ticket says main, but the head is not on main" failed; return 0
  fi
  local meta
  if ((BOUND)); then
    # The forge chose the metadata commit at dispatch; it must be reviewed code (on main) and carry
    # exactly the policy the job was bound to.
    if ! "${git_auth[@]}" git -C "$src" merge-base --is-ancestor "$mcommit" refs/remotes/origin/main 2>/dev/null; then
      refuse not-on-main "the job's metadata commit ${mcommit:0:12} is not on main"; return 0
    fi
    if [[ "$(policy_bytes "$src" "$mcommit" | sha256sum | cut -c1-64)" != "$psha" ]]; then
      refuse policy-mismatch "the policy at ${mcommit:0:12} does not hash to the job's ${psha:0:12}"; return 0
    fi
    meta=$mcommit policy_source="job metadata $mcommit"
  fi
  if ! "${git_auth[@]}" git -C "$src" -c advice.detachedHead=false checkout -q --detach "$head" 2>&1; then
    beat_finish "$owner/$repo" "$head" failed "$((SECONDS - started))" "head is not in the clone"; return 0
  fi
  ((BOUND)) || choose_meta "$src" "$base" "$mode" "$branch"
  if ! prepare_tree "$src" "$meta"; then
    beat_finish "$owner/$repo" "$head" failed "$((SECONDS - started))" "the tree could not be made safe to audit"; return 0
  fi
  # The invocations are the family's own: a full job as ops/ci/score.sh audits a whole tree (advisory
  # mode, so the forge, not the tool, decides), a diff job exactly as ops/ci/jankurai-gate.sh renders
  # the host's (skipping the proof plan when there is no owner map to prove lanes against).
  local -a args
  if [[ "$mode" == full ]]; then
    # The policy is named in-tree: jankurai 1.7 refuses any other --policy source. prepare_tree has
    # already written the trusted bytes there (and hidden the edit from the diff).
    args=(audit . --full --mode advisory --policy agent/audit-policy.toml --json "$out" --no-score-history)
  else
    args=(diff-audit "$src" --base-ref "$base" --json "$out" --advisory-only)
    [[ -f "$src/agent/owner-map.json" ]] || args+=(--skip-proof)
  fi
  # The assigned auditor is checked again right before it runs: a digest pruned or replaced since the
  # claim is never run in its place.
  if ((BOUND)) && ! receipt="$(verify_staged "$a_sha" "$a_ver" "$a_target" "$a_signer")"; then
    [[ "$receipt" == staged-digest-missing ]] && receipt="tool-gone"
    refuse "$receipt" "the assigned auditor changed or vanished after the claim"; return 0
  fi
  if [[ "$origin" == contributed ]]; then
    # Only this disposable tree is mounted. Authentication files and the host installation stay
    # outside it; the verified auditor is copied beside (never into) the untrusted source tree.
    cp -- "$bin" "$WORK_DIR/tree/auditor"
    chmod 0555 "$WORK_DIR/tree/auditor"
    if [[ "$(sha256sum <"$WORK_DIR/tree/auditor" | cut -c1-64)" != "$a_sha" ]]; then
      refuse verifier-mismatch "the sandbox auditor copy differs from the assignment"; return 0
    fi
    ( cd "$src"; exec 9>&-
      exec env -i PATH="$SANDBOX_PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 PR_GATE_SANDBOX=1 \
        timeout --kill-after=30s "$AUDIT_TIMEOUT" nice -n 10 ionice -c 3 \
        "${sandbox_cmd[@]}" "$WORK_DIR/tree" src \
        "${audit_env[@]}" "$WORK_DIR/tree/auditor" "${args[@]}"
    ) >"$WORK_DIR/audit.log" 2>&1 || exit_code=$?
  else
    ( cd "$src" && "${audit_env[@]}" timeout "$AUDIT_TIMEOUT" nice -n 10 ionice -c 3 "$bin" "${args[@]}" ) \
      >"$WORK_DIR/audit.log" 2>&1 || exit_code=$?
  fi
  # The auditor's output can quote the head; only a bounded, printable tail reaches the journal.
  tail -n 3 "$WORK_DIR/audit.log" | LC_ALL=C tr -cd '[:print:]\n' | cut -c1-200 | sed 's/^/  /' || true

  local conclusion=scored reason=""
  ((exit_code == 0)) || { conclusion="tool-failed"; reason="jankurai exited $exit_code"; }
  if [[ -f "$out" && ! -L "$out" ]] && jq -e 'type == "object"' "$out" >/dev/null 2>&1; then
    # Unbound, the report names the policy it was scored by; bound, the binding itself does.
    ((BOUND)) || { jq --arg source "$policy_source" --arg sha "$(sha256sum "$WORK_DIR/policy.toml" | cut -d' ' -f1)" \
      '. + {jeryu_audit_policy: {source: $source, sha256: $sha}}' "$out" >"$out.tmp" && mv -f -- "$out.tmp" "$out"; }
  else
    rm -f -- "$out"
    printf 'null\n' >"$out"
  fi
  if ((BOUND)); then
    jq -n --arg branch "$branch" --arg head "$head" --arg base "$base" --arg runner "$RUNNER_ID" \
      --arg mode "$mode" --argjson exit "$exit_code" --slurpfile report "$out" --arg job "$job" \
      --argjson auditor "$auditor" --arg mcommit "$mcommit" --arg psha "$psha" --arg receipt "$receipt" '
      {branch: $branch, commit_sha: $head, head_sha: $head, base_sha: $base, runner_id: $runner,
       jankurai_version: ("jankurai " + $auditor.version), jankurai_sha256: $auditor.binary_sha256,
       jankurai_receipt_sha256: $receipt, receipt_sha256: $receipt, audit_mode: $mode, tool_exit: $exit,
       report: $report[0], job_id: $job, auditor: $auditor, metadata_commit: $mcommit, policy_sha256: $psha}' >"$request"
    beat_state publishing
  else
    jq -n --arg branch "$branch" --arg head "$head" --arg base "$base" --arg runner "$RUNNER_ID" \
      --arg version "$JERYU_JANKURAI_VERSION" --arg sha "$JERYU_JANKURAI_SHA256" \
      --arg receipt "${JERYU_JANKURAI_RECEIPT_SHA256:-}" --arg mode "$mode" --argjson exit "$exit_code" \
      --slurpfile report "$out" '
      {branch: $branch, commit_sha: $head, base_sha: $base, runner_id: $runner,
       jankurai_version: $version, jankurai_sha256: $sha, audit_mode: $mode, tool_exit: $exit,
       report: $report[0]}
      + (if ($receipt | test("^[0-9a-f]{64}$")) then {jankurai_receipt_sha256: $receipt} else {} end)' >"$request"
  fi
  api POST "/api/v1/repos/$owner%2F$repo/jankurai-scores" "$request"
  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    if [[ "$(jq -r '.recorded_as // ""' <<<"$body" 2>/dev/null)" == qualification ]]; then
      [[ "$conclusion" != scored ]] || conclusion=qualified
      say "$owner/$repo@$head recorded as qualification $(clean "$(jq -r '.qualification // "?"' <<<"$body" 2>/dev/null)" 80) for jankurai $a_ver"
    else
      say "$owner/$repo@$head scored $(jq -r '.score // "?"' <<<"$body" 2>/dev/null || echo "?") ($mode audit, $( ((BOUND)) && echo "jankurai $a_ver, job $job" || echo "$JERYU_JANKURAI_VERSION"), policy: $policy_source)"
    fi
  else
    say "$owner/$repo@$head report refused (HTTP $code): $(clean "$body")"
    if ((BOUND)); then
      conclusion="rejected-publication"
      reason="$(clean "$(jq -r '[.code // .error // empty, .field // empty] | join(": ")' <<<"$body" 2>/dev/null)" 200)"
      reason="the forge refused the report (HTTP $code${reason:+; $reason})"
    else
      conclusion=refused reason="the forge refused the report (HTTP $code)"
    fi
  fi
  beat_finish "$owner/$repo" "$head" "$conclusion" "$((SECONDS - started))" "$reason"
  rm -rf -- "$src"
}

# One job's failure is that job's: whatever a head does to its own audit, the pass goes on, the claim
# is reported finished, and the next job runs. Each job runs in its own subshell, started in the
# background and waited for, so `set -e` stays in force inside it (a subshell tested by `if` would
# run with it silently off) and its keepalive dies with it.
for job in "${jobs[@]}"; do
  ( trap stop_keepalive EXIT; audit_one "$job" ) &
  if ! wait "$!"; then
    beat_finish "$(jq -r '"\(.owner)/\(.repo)"' <<<"$job" 2>/dev/null || echo unknown)" \
      "$(jq -r '.head // ""' <<<"$job" 2>/dev/null)" failed 0 "the audit stopped unexpectedly"
  fi
done
