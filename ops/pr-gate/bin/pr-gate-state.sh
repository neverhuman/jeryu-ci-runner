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

gate_main_health_context() {
  printf '%s/main-health' "$2"
}

gate_status_context() {
  if [[ "${GATE_CONTEXT_KIND:-required}" == main-health ]]; then
    gate_main_health_context "$1" "$2"
  else
    gate_required_context "$1" "$2"
  fi
}

# How the attempt under preparation executes: on the gate host as the operator identity, or in the
# site's ephemeral token-free sandbox because the head is a contribution. It is part of the input
# identity, so a sandboxed result is never reused for a host-run one or the other way round.
gate_execution_kind() {
  [[ "${GATE_SANDBOX:-0}" == 1 ]] && printf 'sandboxed-contribution' || printf 'operator-unsealed'
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
# directory (replacing an older copy there), printing each name moved. See the runner's step 5.
gate_detach_strays() { # tree detached-dir name...
  local tree=$1 detached=$2 d n; shift 2
  for d in "$tree"/*/; do
    n=$(basename "$d")
    [[ -d "$d/.git" && " $* " != *" $n "* ]] || continue
    mkdir -p "$detached" && rm -rf -- "${detached:?}/$n" && mv -- "${d%/}" "$detached/$n" || return
    printf '%s\n' "$n"
  done
}

# Evidence repositories are read by exact tag/commit/tree from outside a gate's family (a docs
# repository reading another owner's release evidence, say). Keep a bare <name>.git of each beside
# the family checkouts: it has no .git subdirectory, so gate_detach_strays leaves it alone. A refresh
# that fails is reported, never fatal: only the repository that reads the evidence needs it, and it
# fails closed on its own with a precise message.
gate_mirror_evidence() { # tree base owner/name...
  local tree=$1 base=$2 e dest; shift 2
  for e in "$@"; do
    [[ "$e" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { printf 'evidence %s: not owner/name\n' "$e"; continue; }
    dest="$tree/${e#*/}.git"
    if [[ ! -d "$dest" ]] && ! git clone --quiet --bare "$base/git/$e.git" "$dest" 2>/dev/null; then
      rm -rf -- "$dest"; printf 'evidence %s: cannot mirror\n' "$e"; continue
    fi
    git -C "$dest" fetch --quiet --prune "$base/git/$e.git" \
      '+refs/heads/main:refs/heads/main' '+refs/tags/*:refs/tags/*' 2>/dev/null ||
      printf 'evidence %s: cannot refresh\n' "$e"
  done
}

# The evidence repositories configured for one tree owner: PR_GATE_EVIDENCE_REPOS lists
# <tree-owner>=<owner>/<name> entries.
gate_evidence_for() { # tree-owner
  local entry
  for entry in ${PR_GATE_EVIDENCE_REPOS:-}; do
    [[ "${entry%%=*}" == "$1" && "$entry" == *=* ]] && printf '%s\n' "${entry#*=}"
  done
  return 0
}

# Every pr-gate runner's status description starts "pr-gate-runner@<host> ". Which host posted it is
# for people reading the PR; it is not part of what a result proves, so nothing below compares it.
GATE_RUNNER_NAME=pr-gate-runner

# The newest status of this gate's required context on a status snapshot, when a pr-gate runner posted
# it as this gate identity; else nothing. Who posted a status is the forge's `creator.login` (jeryu
# returns it on the combined status, GET /repos/:o/:r/commits/:sha/status; jeryu-deploy
# crates/jeryu-api/src/github/commit_status.rs), never the description, which anyone allowed to post a
# status can write. A row without a creator counts only when its description is this host's own marker,
# which is what keep-green trusted before; it is never reused (see gate_decision).
gate_newest_runner_status() { # status-snapshot
  jq -ec --arg context "$(gate_status_context "$owner" "$repo")" --arg prefix "$GATE_RUNNER_NAME@" \
    --arg own "${MARKER:-} " --arg identity "${IDENTITY:-}" '
    [.statuses[]? | select(.context == $context)] | sort_by(.updated_at // .created_at) | last
    | select(. != null and ((.description // "") | startswith($prefix)))
    | select(if (.creator.login // "") == "" then (.description | startswith($own))
             else $identity != "" and .creator.login == $identity end)' "$1" 2>/dev/null
}

# True when the newest status of this gate's required context is a pr-gate runner's success. A
# re-verification of such a head does not post `pending` over it, whichever host posted it.
gate_newest_is_own_success() { # status-snapshot
  gate_newest_runner_status "$1" | jq -e '.state == "success"' >/dev/null 2>&1 && return 0
  jq -e --arg context "$(gate_status_context "$owner" "$repo")" --arg marker "${MARKER:-} " '
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
    --arg kind "$(gate_execution_kind)" --argjson toolchain "${GATE_TOOLCHAIN_PATHS:-[]}" \
    '{schema:"jeryu.pr-gate-attempt/v1",id:$id,owner:$owner,repo:$repo,sha:$sha,
      boot_id:$boot,pid:$pid,slot:$slot,sequence:$sequence,started_at:$at,inputs:$inputs[0],
      terminal:false,outcome:null,exit_code:null,log:null,log_sha256:null,gate_definition_paths:[],
      queue_wait:null,
      publication:{required_status:false,check_run:false},recovery_required:null,
      execution_kind:$kind,toolchain_paths:$toolchain}' | gate_atomic "$gate_receipt"
}

# Hash a fixture or vendor tree for the input identity. A native build may be running in the same
# directory: one gate aborted with exit 123 when sha256sum met the CMake scratch
# files under target/native-vendor/.build (train.cpp-265d130e.o.tmp and friends) that vanished between
# find and hash. Live scratch is not an input, so .build directories and *.tmp files are excluded, and
# a file that disappears anyway is recorded as vanished instead of ending the gate. The identity stays
# honest: a vanished path is named in the record, so it cannot silently match a later run.
# Each line names the file relative to the tree, under the tree's label: where a host keeps the tree
# is not an input, so the same tree hashes the same on every host.
hash_fixture_tree() { # root [label] [all]
  local root=${1%/} label=${2:-.} file digest name prefix walk_pid
  local -a filters=() files=()
  [[ "${3:-}" == all ]] || filters=(-not -path '*/.build/*' -not -name '*.tmp')
  mapfile -d '' -t files < <(set -o pipefail; find -L "$root" -ignore_readdir_race -type f "${filters[@]}" -print0 | LC_ALL=C sort -z)
  walk_pid=$!
  wait "$walk_pid" || { printf 'cannot walk input tree: %s\n' "$label" >&2; return 1; }
  for file in "${files[@]}"; do
    name="$label/${file#"$root"/}" prefix=""
    if [[ "$name" == *$'\n'* || "$name" == *'\'* ]]; then
      name=${name//\\/\\\\}; name=${name//$'\n'/\\n}; prefix='\'
    fi
    if digest=$(sha256sum <"$file" 2>/dev/null); then
      printf '%s%s  %s\n' "$prefix" "${digest:0:64}" "$name"
    else
      # Executable directories must be fully readable; absence/EACCES cannot prove equal bytes.
      if [[ "${3:-}" == all ]]; then
        printf 'cannot bind executable input: %s\n' "$name" >&2
        return 1
      fi
      printf '%svanished-during-hash  %s\n' "$prefix" "$name"
    fi
  done
}

# One executable's line in the input identity: its content hash and the name the gate calls it by.
# The path it resolved to is a property of the host, not of what runs.
gate_tool_line() { # name path
  local digest
  digest=$(sha256sum <"$2") || return
  [[ "$digest" =~ ^[0-9a-f]{64} ]] || return 1
  printf '%s  %s\n' "${digest:0:64}" "$1"
}

# A path as the identity spells it: under the running user's home it is written "~/...", so the same
# layout in two homes is the same input.
gate_portable_path() { # path
  if [[ "$1" == "$HOME" || "$1" == "$HOME/"* ]]; then printf '~%s' "${1#"$HOME"}"; else printf '%s' "$1"; fi
}

# Everything the recipe can execute that is not already bound by name, as identity lines. A result is
# reused on another host only when that host computes the same identity, so the identity must change
# whenever the recipe could see different bytes -- not only the named tools, but every directory on the
# recipe's PATH ($RECIPE_PATH, the one PATH the runner gives the recipe and its prefetch) and the
# libraries they load:
#   - a system directory (under /usr but not /usr/local, or /bin, /sbin) is the package manager's: its
#     listing (names, sizes, link targets) plus the installed package set, which also binds /usr/lib;
#   - any other directory (the user's ~/.local/bin, ~/.cargo/bin, /usr/local/bin, ...) by content;
#   - the operating system release, architecture and kernel release;
#   - the active Rust toolchain's whole bin directory and its installed components;
#   - Python distributions installed outside the package manager (user and /usr/local site packages).
# A host whose package set cannot be read binds a value unique to it, so it never shares results.
gate_host_environment() {
  local directory system=0 packages machine
  local -a directories=()
  printf 'os  %s\n' "$( . /etc/os-release 2>/dev/null; printf '%s %s' "${ID:-unknown}" "${VERSION_ID:-unknown}")"
  printf 'arch  %s\n' "$(uname -m)"
  printf 'kernel  %s\n' "$(uname -r)"
  IFS=: read -r -a directories <<<"${RECIPE_PATH:-}"
  for directory in "${directories[@]}"; do
    [[ -n "$directory" && -d "$directory" ]] || continue
    [[ "$directory" != "${TOOLS:-}" ]] || continue
    case "$directory" in
      /usr/local|/usr/local/*) hash_fixture_tree "$directory" "path:$(gate_portable_path "$directory")" all || return;;
      /usr/*|/bin|/sbin)
        system=1
        printf '%s  path:%s (listing)\n' \
          "$(find "$directory" -maxdepth 1 -mindepth 1 -printf '%f %s %l\n' | LC_ALL=C sort | sha256sum | cut -c1-64)" "$directory";;
      *) hash_fixture_tree "$directory" "path:$(gate_portable_path "$directory")" all || return;;
    esac
  done
  if ((system)); then
    packages=""
    if command -v dpkg-query >/dev/null; then
      packages=$(set -o pipefail; dpkg-query -W -f '${Package}:${Architecture}=${Version}\n' | LC_ALL=C sort | sha256sum | cut -c1-64) || packages=""
    elif command -v rpm >/dev/null; then
      packages=$(set -o pipefail; rpm -qa --qf '%{NAME}.%{ARCH}=%{EPOCH}:%{VERSION}-%{RELEASE}\n' | LC_ALL=C sort | sha256sum | cut -c1-64) || packages=""
    elif command -v apk >/dev/null; then
      packages=$(set -o pipefail; apk info -v 2>/dev/null | LC_ALL=C sort | sha256sum | cut -c1-64) || packages=""
    fi
    if [[ -z "$packages" ]]; then
      machine=$(cat /etc/machine-id 2>/dev/null || hostname)
      packages="unbound-$(printf '%s' "$machine" | sha256sum | cut -c1-64)"
    fi
    printf '%s  system-packages\n' "$packages"
  fi
  local toolchain=${GATE_BOUND_RUSTC:-}
  if [[ -n "$toolchain" ]]; then
    hash_fixture_tree "$(dirname -- "$toolchain")" toolchain-bin all || return
    printf '%s  toolchain-components\n' \
      "$(env -u RUSTUP_TOOLCHAIN rustup component list --toolchain "$(basename -- "$(dirname -- "$(dirname -- "$toolchain")")")" --installed 2>/dev/null | LC_ALL=C sort | sha256sum | cut -c1-64)"
  fi
  printf '%s  python-distributions\n' "$(find "$HOME"/.local/lib/python3* /usr/local/lib/python3* -maxdepth 2 \
    -name '*.dist-info' -printf '%f\n' 2>/dev/null | LC_ALL=C sort | sha256sum | cut -c1-64)"
}

# The site configuration as an input: the SHA-256 of the settings that can change a gate's verdict.
# Settings that only say where this host keeps things, which credential it reads, which heads it
# chooses, or when it wakes are left out -- two hosts configured alike for those differ only in them,
# and a result proved on one must be reusable on the other. What they point at is bound where it
# matters: tools, runtime tools and the vendor tree by content, the sources by commit, the sandbox
# by command. Every other key is bound, so a setting added later re-gates until it is listed here.
# GATE_RUNNER_FAMILY and the checkout roots only choose which sibling checkouts form the tree; the
# sources rows bind exactly which repositories at which commits were there.
GATE_HOST_LOCAL_SETTINGS='JERYU_TOKEN_FILE GATE_RUNNER_HOME GATE_RUNNER_TOOLS GATE_RUNNER_RUNTIME_TOOLS GATE_RUNNER_SCRIPT GATE_RUNNER_FAMILY
  GATE_RUNNER_NATIVE_VENDOR GATE_RUNNER_SCCACHE GATE_RUNNER_SCCACHE_DIR GATE_RUNNER_SCCACHE_SIZE
  GATE_RUNNER_SLOT GATE_RUNNER_OWNERS GATE_RUNNER_REPOS GATE_RUNNER_REGATE_SETTLE GATE_RUNNER_WAKE_*
  GATE_INSTALL_* PR_GATE_CHECKOUT_ROOTS PR_GATE_CHECKOUT_ROOT_PATTERN PR_GATE_CODE_REPO PR_GATE_SOURCE_*
  PR_GATE_GOVERNED_JANKURAI PR_GATE_LOG_URL_TEMPLATE'
# Not host-local, though they choose heads rather than judge them: PR_GATE_OK_TO_TEST_* and
# PR_GATE_CONTRIBUTED_LABEL decide whether outside code may run at all, and a host that would not have
# admitted a head must not adopt a result another host's wider allowlist produced.

# The effective site configuration is bound even when no site file is readable: what
# pr_gate_load_config leaves in effect, not the file's text. A value set in the environment (a
# systemd Environment= line, a per-slot drop-in) wins over the file, and of repeated keys in the file
# the first wins, exactly as the loader decides. Comments, blank lines and order change nothing; a
# value under the running user's home is spelled "~/..." either way.
gate_site_config_digest() { # file
  local file=$1 line key value
  local -A effective=()
  local source=absent
  [[ ! -f "$file" || ! -r "$file" ]] || source=readable
  if [[ "$source" == readable ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
    [[ "$key" =~ ^(PR_GATE_|GATE_RUNNER_|GATE_INSTALL_|JERYU_) ]] || continue
    [[ "$key" != PR_GATE_CONFIG && "$key" != PR_GATE_CONFIG_FILE && -z "${effective[$key]+set}" ]] || continue
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
    # shellcheck disable=SC2088  # a literal "~/" in the data, as the loader reads it
    [[ "$value" != "~/"* ]] || value="$HOME/${value#"~/"}"
    [[ -z "${!key+set}" ]] || value=${!key}
    effective[$key]=$value
  done <"$file"
  fi
  while IFS= read -r key; do
    [[ "$key" != PR_GATE_CONFIG && "$key" != PR_GATE_CONFIG_FILE ]] || continue
    effective[$key]=${!key}
  done < <(compgen -v | grep -E '^(PR_GATE_|GATE_RUNNER_|GATE_INSTALL_|JERYU_)' || true)
  {
  jq -nc --arg source "$source" '{source:$source}'
  for key in "${!effective[@]}"; do
    ! pr_gate_listed "$GATE_HOST_LOCAL_SETTINGS" "$key" || continue
    jq -nc --arg key "$key" --arg value "$(gate_portable_path "${effective[$key]}")" '{key:$key,value:$value}'
  done
  } | LC_ALL=C sort | sha256sum | cut -c1-64
}

# The digest a published result carries for its input identity. Anything that reads the inputs back
# (another host deciding whether to reuse, a person comparing receipts) recomputes it the same way.
# Fails, rather than printing the digest of nothing, when the inputs cannot be read.
gate_inputs_digest() { # inputs-json
  local canonical
  canonical=$(jq -ceS 'objects' "$1") || return
  printf '%s\n' "$canonical" | sha256sum | cut -c1-64
}

gate_inputs() {
  : "${run:?}" "${recipe_name:?}"
  # Bind all actual family sources, locks, executable tools and external fixtures.
  # The full identity is retained, so cache invalidation can be independently read.
  local output=$1 directory lock_digest head tree origin clean
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
  gate_input_tools "$inputs" "$versions" || return
  gate_input_render "$output" "$rows" "$inputs" "$versions" "$recipe_name" || return
  rm -f -- "$rows" "$inputs" "$versions"
}

# Everything in the input identity that is not a family source: the executables on PATH, the
# toolchain rustup resolves for the head, the governed tools, the runtime and vendor fixtures, this
# runner's own code and the compiler cache. Appends "sha256  path" lines to $1 and tool versions to
# $2, in a fixed order, because the identity is compared byte for byte.
#
# $3 is a receipt for this exact head. Local compiler paths are optional receipt metadata,
# outside the portable identity. Re-hash those binaries and the rest of the environment; older
# receipts without paths fall through to preparation rather than weakening the comparison.
gate_input_tools() { # inputs versions [previous-receipt]
  local inputs=$1 versions=$2 previous=${3:-} tool resolved
  local -a toolchain=()
  if [[ "${GATE_SANDBOX:-0}" == 1 ]]; then
    # A sandboxed contribution gets none of the host's toolchain, governed tools, runtime fixtures or
    # vendor tree (see the runner's step 6), so none of them is an input of its result. What it
    # evaluates with is the sandbox the site configured, so that is what is bound here.
    printf 'sandbox-command  %s\n' "${SANDBOX_COMMAND:-}" >>"$inputs" || return
    local sandbox_executable
    read -r sandbox_executable _ <<<"${SANDBOX_COMMAND:-}"
    [[ "$sandbox_executable" == /* && -f "$sandbox_executable" ]] || return 1
    gate_tool_line sandbox-executable "$sandbox_executable" >>"$inputs" || return
    printf 'sandbox-host  %s\n' "$(cat /etc/machine-id 2>/dev/null || hostname)" >>"$inputs" || return
    printf 'sandbox-kernel  %s %s\n' "$(uname -m)" "$(uname -r)" >>"$inputs" || return
    printf 'sandbox-os  %s\n' "$(sha256sum /etc/os-release | cut -c1-64)" >>"$inputs" || return
    GATE_TOOLCHAIN_PATHS='[]'
  else
    for tool in bash git just jq rustc cargo rustup cc c++ ld node npm pnpm timeout; do
      resolved=$(command -v "$tool" || true)
      if [[ -n "$resolved" ]]; then gate_tool_line "$tool" "$(readlink -f "$resolved")" >>"$inputs" || return; fi
    done
    if [[ -z "$previous" ]]; then
      for tool in rustc cargo; do
        resolved=$(cd "$run/$repo" && env -u RUSTUP_TOOLCHAIN rustup which "$tool") || return
        toolchain+=("$resolved")
      done
    else
      mapfile -t toolchain < <(jq -er '.toolchain_paths[]' "$previous")
      ((${#toolchain[@]} == 2)) || return 1
      [[ "${toolchain[0]}" == /*/rustc && "${toolchain[1]}" == /*/cargo ]] || return 1
    fi
    GATE_TOOLCHAIN_PATHS=$(printf '%s\n' "${toolchain[@]}" | jq -Rsc 'split("\n")[:-1]') || return
    for resolved in "${toolchain[@]}"; do
      gate_tool_line "toolchain/$(basename -- "$resolved")" "$resolved" >>"$inputs" || return
      "$resolved" --version >>"$versions" || return
    done
    # No mtime-only cache: a changed fixture or governed executable is a new input.
    if [[ -d "$TOOLS" ]]; then hash_fixture_tree "$TOOLS" tools all >>"$inputs" || return; fi
    if [[ -d "$RUNTIME_TOOLS" ]]; then hash_fixture_tree "$RUNTIME_TOOLS" runtime-tools >>"$inputs" || return; fi
    if [[ -n "${VENDOR:-}" && -d "$VENDOR" ]] && pr_gate_listed "${VENDOR_INPUT_REPOS:-}" "$repo" "$owner/$repo"; then
      hash_fixture_tree "$VENDOR" vendor >>"$inputs" || return
    fi
    GATE_BOUND_RUSTC="${toolchain[0]}" gate_host_environment >>"$inputs" || return
  fi
  # The runner's own code, as hashed when this process started (GATE_SELF_SHA256): that is what runs. A
  # runner installed mid-gate replaces the files on disk but not the running copy, and hashing the disk
  # again after the recipe made every gate in flight during an install publish "inputs_changed" as a
  # blocking error although its recipe had passed (jeryu-deploy#35, 2026-09-18 15:12).
  if [[ -n "${GATE_SELF_SHA256:-}" ]]; then
    printf '%s\n' "$GATE_SELF_SHA256" >>"$inputs" || return
  else
    gate_tool_line "$(basename -- "${BASH_SOURCE[0]}")" "${BASH_SOURCE[0]}" >>"$inputs" || return
    gate_tool_line "$(basename -- "$GATE_RUNNER_SCRIPT")" "$GATE_RUNNER_SCRIPT" >>"$inputs" || return
  fi
  if [[ -n "$SCCACHE" && "${GATE_SANDBOX:-0}" != 1 ]]; then gate_tool_line sccache "$SCCACHE" >>"$inputs" || return; fi
}

# Render the portable identity; local compiler locations live on the receipt, outside this identity.
gate_input_render() { # output rows inputs versions recipe
  jq -nS --slurpfile sources "$2" --rawfile tools "$3" --rawfile versions "$4" \
    --arg recipe "$5" --arg base "$BASE" --arg runner "$GATE_RUNNER_NAME" \
    --arg context "$(gate_status_context "$owner" "$repo")" --arg kind "$(gate_execution_kind)" \
    '{schema:"jeryu.pr-gate-inputs/v1",sources:($sources|sort_by(.repository)),tools:$tools,
      versions:$versions,recipe:$recipe,base:$base,runner:$runner,required_context:$context,execution_kind:$kind}' >"$1"
}

# The same input identity, derived without preparing a tree: the siblings read out of the mirrors
# this tick fetched, the gated head's own source row and recipe read off the receipt that pins this
# exact commit, and every tool, fixture and runner hash computed now. Written to $1 from the previous
# terminal result $2, so gate_decision can answer `reuse` or `hold` for an unchanged head without a
# checkout -- ~40 open heads were re-prepared every tick on the gate host only to be found identical.
#
# Nothing is taken on trust. A commit determines its tree and its Cargo.lock, so a receipt whose sha
# is this head is authority for that one row and for nothing else; the recipe and the toolchain
# rustup resolves are functions of that tree and of the just and rustup binaries, whose hashes are
# recomputed here, and the resolved compilers are re-hashed at the paths the receipt names. Every
# other field is computed from the mirrors and the host as it is now, so a sibling main that moved, a
# governed tool that was reinstalled or a runner that was upgraded is a changed input exactly as it is
# after a full preparation. Any difference at all, and anything this cannot derive, returns non-zero:
# the tree is then prepared and the identity computed from the sources themselves, as before.
gate_input_cheap() { # output previous-result
  : "${owner:?}" "${repo:?}" "${sha:?}" "${mirrors:?}" "${family?}"
  local output=$1 previous=$2 n head tree lock_digest row recipe mirror
  local rows="$output.rows" inputs="$output.inputs" versions="$output.versions"
  [[ -f "$previous" ]] || return 1
  jq -e --arg owner "$owner" --arg repo "$repo" --arg sha "$sha" --arg kind "$(gate_execution_kind)" \
    '.terminal and .owner == $owner and .repo == $repo and .sha == $sha
     and (.inputs.execution_kind // "") == $kind' "$previous" >/dev/null 2>&1 || return 1
  row=$(jq -ce --arg repo "$repo" --arg sha "$sha" --arg origin "$BASE/git/$owner/$repo.git" \
    'first(.inputs.sources[]? | select(.repository == $repo and .head == $sha and .origin == $origin))' \
    "$previous") || return 1
  recipe=$(jq -re '.inputs.recipe' "$previous") || return 1
  : >"$rows" || return
  : >"$inputs" || return
  : >"$versions" || return
  printf '%s\n' "$row" >>"$rows" || return
  for n in $family; do
    [[ "$n" != "$repo" ]] || continue
    mirror="$mirrors/$n.git"
    # No mirror, or no canonical main in it, is exactly the sibling the preparation would leave out.
    [[ -d "$mirror" ]] || continue
    head=$(git -C "$mirror" rev-parse refs/heads/main 2>/dev/null) || continue
    tree=$(git -C "$mirror" rev-parse 'refs/heads/main^{tree}' 2>/dev/null) || continue
    lock_digest=absent
    if git -C "$mirror" cat-file -e refs/heads/main:Cargo.lock 2>/dev/null; then
      lock_digest=$(git -C "$mirror" cat-file blob refs/heads/main:Cargo.lock | sha256sum | cut -c1-64) || return
    fi
    jq -nc --arg name "$n" --arg head "$head" --arg tree "$tree" --arg lock "$lock_digest" \
      --arg origin "$BASE/git/$owner/$n.git" \
      '{repository:$name,head:$head,tree:$tree,cargo_lock_sha256:$lock,origin:$origin}' >>"$rows" || return
  done
  gate_input_tools "$inputs" "$versions" "$previous" || return
  gate_input_render "$output" "$rows" "$inputs" "$versions" "$recipe" || return
  rm -f -- "$rows" "$inputs" "$versions"
}

# run, reuse, hold or republish, in gate_action; gate_action_source says whether the evidence was this
# host's receipt (local) or the forge's newest status (forge). This host's own receipt decides first.
# When it has none for these inputs -- another host gated this head, or this host is new -- the
# forge's newest required status decides, if this gate identity posted it from a pr-gate runner and
# it names exactly these inputs: a success is reused and a failure held, as a local one would be.
# There is no log here to re-verify, and none is needed: nothing is published, and the status is the
# gate's verdict wherever it was computed. A retry (--repo/--pr, a re-gate request) still runs.
#
# Adopting a forge result is a deferral, not a verdict: the runner skips such a head while other heads
# need a slot. A durable marker permits only one deferral for the same inputs; the next look runs
# even on a busy tick. An idle tick also re-proves immediately with GATE_FORGE_REUSE=0. A forge
# status never becomes local evidence or a permanent execution exemption.
gate_decision() {
  local identity=$1 retry=$2 statuses=$3 digest deferred
  export gate_action_source=local
  gate_decision_local "$identity" "$retry" "$statuses"
  [[ "$gate_action" == run && "$retry" == 0 && "${GATE_FORGE_REUSE:-1}" == 1 ]] || return 0
  digest=$(gate_inputs_digest "$identity") || return 1
  deferred="$gate_key_dir/forge-deferred.json"
  if [[ -f "$deferred" ]] && jq -e --arg digest "$digest" '.inputs_digest == $digest' "$deferred" >/dev/null; then
    return 0
  fi
  if gate_newest_names_inputs "$statuses" "$identity" success; then
    gate_action=reuse gate_action_source=forge
  elif gate_newest_names_inputs "$statuses" "$identity" failure; then
    gate_action=hold gate_action_source=forge
  fi
  if [[ "$gate_action_source" == forge ]]; then
    jq -nc --arg digest "$digest" --arg at "$(date -u +%FT%TZ)" \
      '{inputs_digest:$digest,deferred_at:$at}' | gate_atomic "$deferred" || return
  fi
}

# True when the newest required status is this identity's runner status in the given state and names
# exactly these inputs. Only a status with a creator counts: the description is not an identity.
gate_newest_names_inputs() { # status-snapshot inputs-json state
  local newest digest
  newest=$(gate_newest_runner_status "$1") || return 1
  digest=$(gate_inputs_digest "$2") || return 1
  # The digest is its own `; inputs <hex>` field, so a longer or shorter hex string cannot match.
  jq -e --arg state "$3" --arg field " inputs $digest" '
    (.creator.login // "") != "" and .state == $state
    and ((.description | split(";") | map(select(startswith(" inputs ")))) == [$field])' <<<"$newest" >/dev/null
}

gate_decision_local() {
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
    # Do not reuse if a later required-context status superseded our publication -- unless that later
    # status is this identity's runner success for exactly these inputs (another host proved the same
    # thing): this host's own verified evidence still stands, and re-proving it would only bounce the
    # head between hosts.
    if jq -e --slurpfile previous "$previous" --arg context "$(gate_status_context "$owner" "$repo")" '
      [.statuses[]? | select(.context == $context)] | sort_by(.updated_at // .created_at)
      | last | .state == "success" and .id == $previous[0].publication.status_id' "$statuses" >/dev/null; then
      gate_action=reuse
    elif gate_newest_names_inputs "$statuses" "$identity" success; then
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

# The paths that define the gate a head is judged by. This runner runs the head's OWN recipe, so a
# change to one of them rewrote the check that is about to report on it, and the result proves only
# what the head's own gate chose to prove. Printed one per line, sorted, for base...head.
# The set is narrow on purpose: the recipe entry point, the CI scripts it calls, and the jankurai and
# policy files those read. Ordinary test directories are not in it -- every PR touches tests, and a
# flag that fires on all of them says nothing. Documentation about the gate does not define it.
gate_definition_paths() { # repo-dir base head
  git -C "$1" diff --name-only "$2...$3" -- \
    ':(glob)**/Justfile' ':(glob)ops/ci/**' ':(glob)ops/jankurai/**' \
    ':(glob)**/*jankurai*' ':(glob)policies/**' ':(glob,exclude)docs/**' 2>/dev/null | LC_ALL=C sort -u
}

# How many of those paths the check run names. A rewrite that touches hundreds of them is already
# said by the first few, and a status payload is not a place for an unbounded list.
GATE_DEFINITION_PATHS_SHOWN=10

# The check-run annotation for a head that changes its own gate, or nothing. Only paths matching a
# relative-path charset are named -- the same allowlist rule as gate_failure_cause, so a path shape
# this runner does not recognise is counted and not published.
gate_self_modification_note() { # receipt
  local paths count shown
  paths=$(jq -r '(.gate_definition_paths // [])[]
    | select(test("^[A-Za-z0-9_][A-Za-z0-9_./-]{0,199}$"))' "$1" 2>/dev/null) || return 0
  [[ -n "$paths" ]] || return 0
  count=$(printf '%s\n' "$paths" | wc -l)
  # A comma is outside the path charset above, so joining on one cannot be misread.
  shown=$(printf '%s\n' "$paths" | head -n "$GATE_DEFINITION_PATHS_SHOWN" | paste -sd, | sed 's/,/, /g')
  ((count <= GATE_DEFINITION_PATHS_SHOWN)) \
    || shown+=" and $((count - GATE_DEFINITION_PATHS_SHOWN)) more"
  printf 'Needs a human: this head changes the gate that judges it (%s). The gate ran this head%s own recipe, so the conclusion above is the head reporting on itself. Read the gate change against protected main before trusting it.' \
    "$shown" "'s"
}

gate_publish() {
  local state outcome id digest exit_code context cause="" log note="" kind review="" inputs
  outcome=$(jq -r '.outcome' "$gate_receipt")
  id=$(jq -r '.id' "$gate_receipt")
  digest=$(jq -r '.log_sha256 // "none"' "$gate_receipt")
  exit_code=$(jq -r '.exit_code // "unknown"' "$gate_receipt")
  # Recover at the admitted context. Old receipts predate explicit binding and
  # used the forge slug; never relabel their old evidence as the corrected gate.
  context=$(jq -er '.inputs.required_context // (.repo + "/required")' "$gate_receipt") || return
  case "$outcome" in success) state=success;; failure|timed_out) state=failure;; *) state=error;; esac
  log=$(jq -r '.log // ""' "$gate_receipt")
  # How the attempt ran is read from its own receipt, so recovering an older one says what that one did.
  kind=$(jq -r '.execution_kind // .inputs.execution_kind // "operator-unsealed"' "$gate_receipt")
  # A contribution that changes what the gate itself evaluates with is named on the check run, beside
  # the self-gate note, so a reviewer sees it needs the extra review as well as a green gate. Never on
  # the required status: its description is the gate's own verdict.
  if jq -e '(.gate_input_paths // []) | length > 0' "$gate_receipt" >/dev/null; then
    review="; gate inputs changed: extra review required"
  fi
  if [[ "$state" != success && -f "$log" ]]; then cause=$(gate_failure_cause "$log"); fi
  # The input identity's digest goes on the status, so a runner on any host can tell that a result
  # proves exactly the inputs it would gate (see gate_decision). A receipt without inputs names none.
  inputs=""
  if jq -e '.inputs | objects' "$gate_receipt" >/dev/null 2>&1; then
    inputs=$(gate_inputs_digest <(jq -c '.inputs' "$gate_receipt")) || return
  fi
  if ! jq -e '.publication.required_status' "$gate_receipt" >/dev/null; then
    api POST "/repos/$owner/$repo/statuses/$sha" "$(jq -nc --arg state "$state" --arg context "$context" \
      --arg description "$MARKER $kind $outcome; exit $exit_code; attempt $id; log $digest${inputs:+; inputs $inputs}${cause:+; cause: $cause}" \
      '{state:$state,context:$context,description:$description}')"
    : "${code:?}" "${body:?}"
    if [[ "$code" != 201 ]] || ! jq -e '.id != null' <<<"$body" >/dev/null; then
      gate_update --arg code "$code" '.recovery_required="required-status publication rejected or unacknowledged" | .publication.http_status=$code' || return
      return 1
    fi
    gate_update --argjson response "$body" '.publication.required_status=true | .publication.status_id=$response.id | .publication.http_status=201' || return
    # The forge stores the description whole (jeryu: no length limit). One that shortened it would drop
    # the digest, and with it every other host's reuse of this result -- safe, but say so.
    if [[ -n "$inputs" ]] && jq -e 'has("description")' <<<"$body" >/dev/null 2>&1 \
        && ! jq -e --arg field "; inputs $inputs" '(.description + ";") | contains($field + ";")' <<<"$body" >/dev/null; then
      printf 'the forge did not keep the inputs digest in %s/%s@%s'"'"'s status; other hosts will re-gate it\n' "$owner" "$repo" "$sha" >&2
    fi
  fi
  if ! jq -e '.publication.check_run' "$gate_receipt" >/dev/null; then
    # A head that changes its own gate is annotated here, on the check run, and never on the required
    # status: the status is the gate, and its description is what the merge panel reads as the verdict.
    # The annotation is advisory -- it changes no conclusion. jeryu's attention inbox raises the
    # matching needs_human item from the same paths, so the PR also shows up on /needs-you.
    note=$(gate_self_modification_note "$gate_receipt")
    api POST "/repos/$owner/$repo/check-runs" "$(jq -nc --arg sha "$sha" --arg state "$state" \
      --arg title "Operator gate $outcome (exit $exit_code)${cause:+: $cause}" --arg summary "Attempt $id; log sha256 $digest; $kind${note:+; changes its own gate}$review" \
      --arg note "$note" \
      '{name:"pr-gate-runner",head_sha:$sha,status:"completed",conclusion:(if $state=="error" then "failure" else $state end),
        output:({title:$title,summary:$summary} + (if $note == "" then {} else {text:$note} end))}')"
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
# The oldest heartbeat shape a forge accepted: identity, labels, and only the identifying fields of
# `current` and `last`. The last resort when a forge refuses a newer shape with 422 even without code
# and tools, so a newer runner against an older forge keeps its slots on /runners.
gate_heartbeat_minimal() { # payload
  jq -c '{runnerId, host, slot, labels,
    current: (.current | if . == null then null else {repo, pr, sha, startedAt} end),
    last: (.last | if . == null then null else {repo, pr, sha, finishedAt, conclusion} end)}' <<<"$1"
}
gate_heartbeat_with() { # payload code-json tools-json
  jq -c --arg code "$2" --arg tools "$3" \
    '. + (if $code != "" then {code: ($code | fromjson)} else {} end)
       + (if $tools != "" then {tools: ($tools | fromjson)} else {} end)' <<<"$1"
}
