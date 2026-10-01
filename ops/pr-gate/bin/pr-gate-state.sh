#!/usr/bin/env bash
# Durable operator-run evidence. This journal does not establish sealed execution.
# The caller holds fd 6 until every worker descendant has exited. Never unlink its
# lock file: a new inode would let another slot enter the same head concurrently.

# The site configuration helpers (pr_gate_lookup, pr_gate_listed), when the caller has not loaded them.
if ! declare -F pr_gate_load_config >/dev/null; then
  # shellcheck source=ops/pr-gate/bin/pr-gate-config.sh
  source "$(dirname -- "${BASH_SOURCE[0]}")/pr-gate-config.sh"
fi

# Match the manifest's exact owner/forge identity. A repository whose family authority names it
# differently from its forge slug requires that name's context; the site lists each such repository in
# PR_GATE_CONTEXT_OVERRIDES as "owner/repo=context" words (exact, case-sensitive). Everything else
# requires <repo>/required.
gate_required_context() {
  local context
  if context=$(pr_gate_lookup "${PR_GATE_CONTEXT_OVERRIDES:-}" "$1/$2") && [[ -n "$context" ]]; then
    printf '%s' "$context"
  else
    printf '%s/required' "$2"
  fi
}

# Durable replace: fsync the new file, rename it, fsync the directory. `sync FILE` fsyncs that file;
# `sync -f` would syncfs the whole filesystem, which on a gate host waited behind every slot's build output
# (sampled 2026-09-18: ~100 of 1300 two-second samples blocked there).
gate_atomic() {
  local destination=$1 temporary
  temporary=$(mktemp "${destination}.XXXXXXXX") || return
  if ! cat >"$temporary" || ! chmod 0600 "$temporary" || ! sync -- "$temporary" \
      || ! mv -f -- "$temporary" "$destination"; then
    rm -f -- "$temporary"
    return 1
  fi
  sync -- "$(dirname -- "$destination")"
}

# Move every checkout in a slot tree that is not one of the named repositories into a detached
# directory (replacing an older copy there), printing each name moved. See the runner's step 3.
gate_detach_strays() { # tree detached-dir name...
  local tree=$1 detached=$2 d n; shift 2
  for d in "$tree"/*/; do
    n=$(basename "$d")
    [[ -d "$d/.git" && " $* " != *" $n "* ]] || continue
    mkdir -p "$detached" && rm -rf -- "${detached:?}/$n" && mv -- "${d%/}" "$detached/$n" || return
    printf '%s\n' "$n"
  done
}

# True when the newest status of this gate's required context on a status snapshot is a success this
# runner posted ($MARKER). A re-verification of such a head does not post `pending` over it.
gate_newest_is_own_success() { # status-snapshot
  jq -e --arg context "$(gate_required_context "$owner" "$repo")" --arg marker "$MARKER " '
    [.statuses[]? | select(.context == $context)] | sort_by(.updated_at // .created_at) | last
    | . != null and .state == "success" and ((.description // "") | startswith($marker))' "$1" >/dev/null
}

gate_lock() {
  local key=$1
  [[ "$key" =~ ^[A-Za-z0-9._-]+-[0-9a-f]{40}$ ]] || return 2
  mkdir -p "$HOME_DIR/claim-locks" "$HOME_DIR/attempts/$key" || return
  chmod 0700 "$HOME_DIR/attempts" "$HOME_DIR/attempts/$key" || return
  exec 6>"$HOME_DIR/claim-locks/$key.lock" || return
  flock -n 6 || { exec 6>&-; return 1; }
  gate_key_dir="$HOME_DIR/attempts/$key"
}

gate_update() {
  local next
  next=$(jq "$@" "$gate_receipt") || return
  printf '%s\n' "$next" | gate_atomic "$gate_receipt"
}

gate_begin() {
  : "${owner:?}" "${repo:?}" "${sha:?}"
  local identity=$1 id sequence=0
  [[ ! -f "$gate_key_dir/sequence" ]] || read -r sequence <"$gate_key_dir/sequence"
  [[ "$sequence" =~ ^[0-9]+$ ]] || return 2
  sequence=$((sequence + 1))
  printf '%s\n' "$sequence" | gate_atomic "$gate_key_dir/sequence"
  id=$(cat /proc/sys/kernel/random/uuid)
  gate_attempt_dir="$gate_key_dir/$id"
  mkdir -m 0700 "$gate_attempt_dir"
  gate_receipt="$gate_attempt_dir/receipt.json"
  jq -n --arg id "$id" --arg owner "$owner" --arg repo "$repo" --arg sha "$sha" \
    --arg boot "$(cat /proc/sys/kernel/random/boot_id)" --arg at "$(date -u +%FT%TZ)" \
    --argjson pid "$$" --argjson sequence "$sequence" --arg slot "$SLOT" --slurpfile inputs "$identity" \
    '{schema:"jeryu.pr-gate-attempt/v1",id:$id,owner:$owner,repo:$repo,sha:$sha,
      boot_id:$boot,pid:$pid,slot:$slot,sequence:$sequence,started_at:$at,inputs:$inputs[0],
      terminal:false,outcome:null,exit_code:null,log:null,log_sha256:null,
      publication:{required_status:false,check_run:false},recovery_required:null,
      execution_kind:"operator-unsealed"}' | gate_atomic "$gate_receipt"
}

# Hash a fixture or vendor tree for the input identity. A native build may be running in the same
# directory: one gate aborted with exit 123 when sha256sum met the CMake scratch
# files under target/native-vendor/.build (train.cpp-265d130e.o.tmp and friends) that vanished between
# find and hash. Live scratch is not an input, so .build directories and *.tmp files are excluded, and
# a file that disappears anyway is recorded as vanished instead of ending the gate. The identity stays
# honest: a vanished path is named in the record, so it cannot silently match a later run.
hash_fixture_tree() {
  local root=$1 file
  while IFS= read -r -d '' file; do
    sha256sum "$file" 2>/dev/null || printf 'vanished-during-hash  %s\n' "$file"
  done < <(find -L "$root" -type f -not -path '*/.build/*' -not -name '*.tmp' -print0 | sort -z)
}

gate_inputs() {
  : "${run:?}" "${recipe_name:?}"
  # Bind all actual family sources, locks, executable tools and external fixtures.
  # The full identity is retained, so cache invalidation can be independently read.
  local output=$1 directory tool resolved lock_digest head tree origin clean
  local rows="$output.rows" inputs="$output.inputs" versions="$output.versions"
  : >"$rows" || return
  : >"$inputs" || return
  : >"$versions" || return
  for directory in "$run"/*; do
    [[ -d "$directory/.git" ]] || continue
    clean=$(git -C "$directory" status --porcelain --untracked-files=normal) || return
    [[ -z "$clean" ]] || return 1
    # A directory with a .git but no commits is not an input: a repository with only a scaffold
    # branch and no mirror, so its slot checkouts were empty, and 'rev-parse HEAD' is a fatal there.
    # That fatal used to leave through the unguarded caller and end the whole tick with exit 128; the
    # fleet produced nothing for 35 minutes on 2026-09-17 because of it. Skip such a directory.
    head=$(git -C "$directory" rev-parse HEAD 2>/dev/null) || continue
    tree=$(git -C "$directory" rev-parse 'HEAD^{tree}' 2>/dev/null) || continue
    origin=$(git -C "$directory" remote get-url origin) || return
    lock_digest=absent
    if [[ -f "$directory/Cargo.lock" ]]; then lock_digest=$(sha256sum "$directory/Cargo.lock" | cut -c1-64) || return; fi
    jq -nc --arg name "$(basename "$directory")" --arg head "$head" \
      --arg tree "$tree" --arg lock "$lock_digest" --arg origin "$origin" \
      '{repository:$name,head:$head,tree:$tree,cargo_lock_sha256:$lock,origin:$origin}' >>"$rows" || return
  done
  for tool in bash git just jq rustc cargo rustup cc c++ ld node npm pnpm timeout; do
    resolved=$(command -v "$tool" || true)
    if [[ -n "$resolved" ]]; then sha256sum "$(readlink -f "$resolved")" >>"$inputs" || return; fi
  done
  for tool in rustc cargo; do
    resolved=$(cd "$run/$repo" && env -u RUSTUP_TOOLCHAIN rustup which "$tool") || return
    sha256sum "$resolved" >>"$inputs" || return
    "$resolved" --version >>"$versions" || return
  done
  # No mtime-only cache: a changed fixture or governed executable is a new input.
  for directory in "$TOOLS" "$RUNTIME_TOOLS"; do
    if [[ -d "$directory" ]]; then
      hash_fixture_tree "$directory" >>"$inputs" || return
    fi
  done
  if [[ -n "${VENDOR:-}" && -d "$VENDOR" ]] && pr_gate_listed "${VENDOR_INPUT_REPOS:-}" "$repo" "$owner/$repo"; then
    hash_fixture_tree "$VENDOR" >>"$inputs" || return
  fi
  # The runner's own code, as hashed when this process started (GATE_SELF_SHA256): that is what runs. A
  # runner installed mid-gate replaces the files on disk but not the running copy, and hashing the disk
  # again after the recipe made every gate in flight during an install publish "inputs_changed" as a
  # blocking error although its recipe had passed (jeryu-deploy#35, 2026-09-18 15:12).
  if [[ -n "${GATE_SELF_SHA256:-}" ]]; then
    printf '%s\n' "$GATE_SELF_SHA256" >>"$inputs" || return
  else
    sha256sum "${BASH_SOURCE[0]}" "$GATE_RUNNER_SCRIPT" >>"$inputs" || return
  fi
  if [[ -n "$SCCACHE" ]]; then sha256sum "$SCCACHE" >>"$inputs" || return; fi
  jq -nS --slurpfile sources "$rows" --rawfile tools "$inputs" --rawfile versions "$versions" \
    --arg recipe "$recipe_name" --arg base "$BASE" --arg runner "$MARKER" \
    --arg context "$(gate_required_context "$owner" "$repo")" \
    '{schema:"jeryu.pr-gate-inputs/v1",sources:($sources|sort_by(.repository)),tools:$tools,
      versions:$versions,recipe:$recipe,base:$base,runner:$runner,required_context:$context,execution_kind:"operator-unsealed"}' >"$output" || return
  rm -f -- "$rows" "$inputs" "$versions"
}

gate_decision() {
  local identity=$1 retry=$2 statuses=$3 previous="$gate_key_dir/last-result.json" actual
  # Output consumed by the sourcing runner after this function returns.
  export gate_action=run
  [[ -f "$previous" ]] || return 0
  jq -e --slurpfile input "$identity" '.terminal and .inputs == $input[0]' "$previous" >/dev/null || return 0
  jq -e '.exit_code != null and .log != null and (.outcome == "success" or .outcome == "failure" or .outcome == "timed_out")' \
    "$previous" >/dev/null || return 0
  gate_result_log=$(jq -r '.log' "$previous")
  # Log paths must remain inside this attempt's immutable evidence directory.
  [[ "$gate_result_log" == "$gate_key_dir/"*/build.log && -f "$gate_result_log" && ! -L "$gate_result_log" ]] || return 0
  actual=$(sha256sum "$gate_result_log" | cut -c1-64)
  [[ "$actual" == "$(jq -r '.log_sha256' "$previous")" ]] || return 0
  [[ "$retry" == 0 ]] || return 0
  if ! jq -e '.publication.required_status and .publication.check_run' "$previous" >/dev/null; then
    gate_action=republish
  elif jq -e '.outcome == "success" and .exit_code == 0' "$previous" >/dev/null; then
    # Do not reuse if a later required-context status superseded our publication.
    if jq -e --slurpfile previous "$previous" --arg context "$(gate_required_context "$owner" "$repo")" '
      [.statuses[]? | select(.context == $context)] | sort_by(.updated_at // .created_at)
      | last | .state == "success" and .id == $previous[0].publication.status_id' "$statuses" >/dev/null; then
      gate_action=reuse
    fi
  else
    gate_action=hold
  fi
}

gate_finish() {
  local outcome=$1 exit_code=$2 build_log=$3 recovery=${4:-} digest=""
  [[ -z "$build_log" ]] || digest=$(sha256sum "$build_log" | cut -c1-64)
  gate_update --arg outcome "$outcome" --argjson exit_code "$exit_code" \
    --arg log "$build_log" --arg digest "$digest" --arg recovery "$recovery" --arg at "$(date -u +%FT%TZ)" \
    'if .terminal then error("attempt already terminal") else
      .terminal=true | .outcome=$outcome | .exit_code=$exit_code | .finished_at=$at |
      .log=(if $log=="" then null else $log end) | .log_sha256=(if $digest=="" then null else $digest end) |
      .recovery_required=(if $recovery=="" then null else $recovery end) end' || return
  cat "$gate_receipt" | gate_atomic "$gate_key_dir/last-result.json"
}

# Why a gate failed, for people reading the PR: the forge's merge panel shows the required status's
# description, which said only "failure; exit 101". gate_failure_cause prints a cause ONLY when the build
# log's first recognised failure is one of a few known shapes, rebuilt from tokens that must match a short
# identifier or relative-path charset -- an allowlist, so nothing free-form from the log is ever published
# (a denylist redactor was rejected in review: a secret it did not know would pass).
# Anything else, or a token outside its charset or length, publishes no cause. The log stays on the runner.
gate_failure_cause() { # log
  local line id='[A-Za-z0-9_][A-Za-z0-9_:.-]{0,79}' rel='[A-Za-z0-9_][A-Za-z0-9_./-]{0,99}' ver='[0-9][0-9A-Za-z.+-]{0,39}'
  local re_missing="^error: no matching package named \`($id)\`"
  local re_download="^error: failed to download \`($id) v($ver)\`"
  local re_panic="^thread '($id)'.* panicked at ($rel):([0-9]{1,6})"
  local re_compile='^error\[(E[0-9]{4})\]'
  local re_step="FAILED STEP \(exit ([0-9]{1,3})\): (bash )?($rel)\$"
  while IFS= read -r line; do
    if [[ "$line" =~ $re_missing ]]; then printf 'missing crate %s from the offline registry' "${BASH_REMATCH[1]}"; return
    elif [[ "$line" =~ $re_download ]]; then printf 'missing crate %s v%s from the offline registry' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return
    elif [[ "$line" =~ $re_panic ]]; then printf 'test panicked: %s at %s:%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; return
    elif [[ "$line" =~ $re_compile ]]; then printf 'compile error %s' "${BASH_REMATCH[1]}"; return
    elif [[ "$line" =~ $re_step ]]; then printf 'step failed (exit %s): %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"; return
    elif [[ "$line" == 'test result: FAILED'* ]]; then printf 'tests failed'; return
    fi
  done < <(sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s#/home/[^ ]*/gate-runner/tree[^/ ]*/##g' "$1" 2>/dev/null)
}

gate_publish() {
  local state outcome id digest exit_code context cause="" log
  outcome=$(jq -r '.outcome' "$gate_receipt")
  id=$(jq -r '.id' "$gate_receipt")
  digest=$(jq -r '.log_sha256 // "none"' "$gate_receipt")
  exit_code=$(jq -r '.exit_code // "unknown"' "$gate_receipt")
  # Recover at the admitted context. Old receipts predate explicit binding and
  # used the forge slug; never relabel their old evidence as the corrected gate.
  context=$(jq -er '.inputs.required_context // (.repo + "/required")' "$gate_receipt") || return
  case "$outcome" in success) state=success;; failure|timed_out) state=failure;; *) state=error;; esac
  log=$(jq -r '.log // ""' "$gate_receipt")
  if [[ "$state" != success && -f "$log" ]]; then cause=$(gate_failure_cause "$log"); fi
  if ! jq -e '.publication.required_status' "$gate_receipt" >/dev/null; then
    api POST "/repos/$owner/$repo/statuses/$sha" "$(jq -nc --arg state "$state" --arg context "$context" \
      --arg description "$MARKER operator-unsealed $outcome; exit $exit_code; attempt $id; log $digest${cause:+; cause: $cause}" \
      '{state:$state,context:$context,description:$description}')"
    : "${code:?}" "${body:?}"
    if [[ "$code" != 201 ]] || ! jq -e '.id != null' <<<"$body" >/dev/null; then
      gate_update --arg code "$code" '.recovery_required="required-status publication rejected or unacknowledged" | .publication.http_status=$code' || return
      return 1
    fi
    gate_update --argjson response "$body" '.publication.required_status=true | .publication.status_id=$response.id | .publication.http_status=201' || return
  fi
  if ! jq -e '.publication.check_run' "$gate_receipt" >/dev/null; then
    api POST "/repos/$owner/$repo/check-runs" "$(jq -nc --arg sha "$sha" --arg state "$state" \
      --arg title "Operator gate $outcome (exit $exit_code)${cause:+: $cause}" --arg summary "Attempt $id; log sha256 $digest; operator-unsealed" \
      '{name:"pr-gate-runner",head_sha:$sha,status:"completed",conclusion:(if $state=="error" then "failure" else $state end),
        output:{title:$title,summary:$summary}}')"
    # The check run is not a required context and never gates a merge: the required status above is
    # the gate. A rejection is recorded and reported, and must not hold the attempt in recovery or
    # stop later ticks, which is what a return 1 here did.
    if [[ "$code" != 201 ]]; then
      gate_update --arg code "$code" '.publication.check_run=false | .publication.check_http_status=$code | .recovery_required=null' || return
      printf 'check run for %s/%s@%s answered %s (required status already posted)\n' "$owner" "$repo" "$sha" "$code" >&2
    else
      gate_update '.publication.check_run=true | .recovery_required=null' || return
    fi
  fi
  cat "$gate_receipt" | gate_atomic "$gate_key_dir/last-result.json"
}

gate_recover() {
  local receipt newest="" sequence maximum=0 newest_id=""
  for receipt in "$gate_key_dir"/*/receipt.json; do
    [[ -f "$receipt" ]] || continue
    sequence=$(jq -er '.sequence' "$receipt") || return
    if ((sequence > maximum)); then maximum=$sequence; newest=$receipt; fi
  done
  [[ -z "$newest" ]] || newest_id=$(jq -r '.id' "$newest")
  for receipt in "$gate_key_dir"/*/receipt.json; do
    [[ -f "$receipt" ]] || continue
    gate_receipt=$receipt
    if [[ "$receipt" != "$newest" ]]; then
      # A historical outbox item must never overwrite a newer execution result.
      gate_update --arg latest "$newest_id" '
        if .terminal then . else .terminal=true | .outcome="interrupted" end |
        .publication.superseded_by=$latest | .recovery_required=null' || return
      continue
    fi
    if ! jq -e '.terminal' "$receipt" >/dev/null; then
      gate_finish interrupted null "" 'exclusive descendant lock recovered without a process-exit receipt' || return
    fi
    if ! jq -e '.publication.required_status and .publication.check_run' "$receipt" >/dev/null; then
      gate_publish || return 1
    fi
  done
  gate_receipt=""
}

gate_exit() {
  local result=$?
  trap - EXIT
  if [[ -n "${gate_receipt:-}" && -f "$gate_receipt" ]] \
      && ! jq -e '.terminal' "$gate_receipt" >/dev/null; then
    gate_finish interrupted null "" "runner exited $result without a verified worker result" || true
    gate_publish || true
  fi
  [[ -z "${AUTH_CONFIG:-}" ]] || rm -f -- "$AUTH_CONFIG"
  exit "$result"
}

gate_signal() {
  local signal=$1 result=$2
  trap '' TERM INT HUP
  if [[ -n "${gate_worker:-}" ]]; then
    kill -"$signal" -- "-$gate_worker" 2>/dev/null || true
    wait "$gate_worker" 2>/dev/null || true
  fi
  exit "$result"
}

# Re-gating on a sibling's main (owner decision, 2026-09-19): when a family main moves, every open head
# of that family is re-gated automatically -- gate_inputs binds every sibling's head, so the moved main
# is a changed input and gate_decision answers `run`, the same way the merge queue rebuilds an entry on
# a moved base. The bound: a burst of merges is coalesced. The runner records the family's mains after
# each mirror fetch; the file changes (and so its mtime moves) only when some main really moved. While
# that is younger than the settle window, heads that were already gated wait, so a burst costs each PR
# one re-gate after it rather than one per merge. A PR has one head, and one claim lock per head, so it
# never has more than one re-gate pending or running. New heads and queue entries are never deferred.
gate_record_mains() { # record-file mirrors-dir name...
  local record=$1 mirrors=$2 n head current
  shift 2
  current=$(for n in "$@"; do
    head=$(git -C "$mirrors/$n.git" rev-parse --verify --quiet refs/heads/main 2>/dev/null) || continue
    printf '%s %s\n' "$n" "$head"
  done | sort -u) || return
  [[ -f "$record" && "$(cat "$record")" == "$current" ]] && return 0
  printf '%s\n' "$current" | gate_atomic "$record"
}

# True while the recorded mains moved less than settle seconds ago (now defaults to the clock).
gate_regate_settling() { # record-file settle-seconds [now]
  local record=$1 settle=$2 now=${3:-$(date +%s)} moved
  [[ -f "$record" && "$settle" =~ ^[0-9]+$ ]] || return 1
  moved=$(stat -c %Y -- "$record") || return 1
  ((now - moved < settle))
}

# The code this host's runner scripts are, as the `code` object of a /runners heartbeat, or nothing.
# Its one source is installed-main.json, which pr-gate-install.sh writes ($STATE there) after every
# install or verification: {commit, previous, installed_at, files} or {commit, verified_at}, each
# with an optional `version` (`pr-gate <VERSION>`), passed on only as 1..=100 chars with no control
# chars. A file that is missing, unreadable, or whose commit is not a full hex object id prints
# nothing, and the heartbeat then carries no `code` key at all. PR_GATE_CODE_REPO (site config) names
# the forge repo of that code, as owner/repo; unset, no `code` is reported either.
gate_runner_code() { # gate-runner-home
  local state="$1/installed-main.json"
  [[ -f "$state" && -r "$state" && -n "${PR_GATE_CODE_REPO:-}" ]] || return 0
  jq -nc --arg repo "$PR_GATE_CODE_REPO" '
    input
    | select(type == "object" and (.commit | type) == "string"
             and (.commit | test("^([0-9a-f]{40}|[0-9a-f]{64})$")))
    | (.installed_at // .verified_at) as $at
    | {repo: $repo, commit: .commit}
      + (if ($at | type) == "string" and $at != "" then {installedAt: $at} else {} end)
      + (if (.version | type) == "string" and (.version | length) >= 1 and (.version | length) <= 100
            and (.version | explode | all(. >= 32 and (. < 127 or . > 159)))
         then {version: .version} else {} end)' "$state" 2>/dev/null || true
}

# What this host's gates evaluate with, as the `tools` array of a /runners heartbeat, or nothing.
# Its one source is tools.json, which pr-gate-install.sh writes on every run (~10 min):
# {generated_at, tools:[{name, version?, sha256?}]}. Each entry is passed on only if it meets the
# forge contract: name 1..=64 of [a-z0-9._@-] and unique (first wins), version 1..=100 chars with no
# control chars, sha256 64 lowercase hex; an invalid version or sha256 is dropped from its entry, an
# invalid name drops the entry. At most 32 entries. A missing or unreadable file, or no valid entry,
# prints nothing, and the heartbeat then carries no `tools` key at all.
gate_runner_tools() { # gate-runner-home
  local state="$1/tools.json"
  [[ -f "$state" && -r "$state" ]] || return 0
  jq -nc '
    input
    | select(type == "object" and (.tools | type) == "array")
    | [ .tools[]
        | select(type == "object" and (.name | type) == "string" and (.name | test("^[a-z0-9._@-]{1,64}$")))
        | {name: .name}
          + (if (.version | type) == "string" and (.version | length) >= 1 and (.version | length) <= 100
                and (.version | explode | all(. >= 32 and (. < 127 or . > 159)))
             then {version: .version} else {} end)
          + (if (.sha256 | type) == "string" and (.sha256 | test("^[0-9a-f]{64}$")) then {sha256: .sha256} else {} end) ]
    | reduce .[] as $t ([]; if any(.[]; .name == $t.name) then . else . + [$t] end)
    | .[0:32]
    | select(length > 0)' "$state" 2>/dev/null || true
}

# A heartbeat payload with the optional code and tools added (each only when non-empty).
gate_heartbeat_with() { # payload code-json tools-json
  jq -c --arg code "$2" --arg tools "$3" \
    '. + (if $code != "" then {code: ($code | fromjson)} else {} end)
       + (if $tools != "" then {tools: ($tools | fromjson)} else {} end)' <<<"$1"
}
