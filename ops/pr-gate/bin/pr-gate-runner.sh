#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pr-gate-runner.sh — gate open family PRs on a gate host and post <repo>/required.
#
# Branch protection holds every family PR on an exact-head `<repo>/required`
# status, and nothing posted one on its own: a status posted by hand came from
# whatever host the operator happened to be on. This runs each repository's own
# unmodified gate recipe on one gate host, from a systemd --user timer.
#
# One tick:
#   1. under a lock, list open PRs on the gated repos;
#   2. pick the oldest head that has no <repo>/required status posted BY THIS
#      RUNNER (manual statuses are re-proved here, because they were produced
#      on another host's toolchain);
#   3. build a clean tree: every family repo at origin/main from local mirrors,
#      the PR's repo at exactly its head, the configured native vendor tree linked;
#   4. post `pending`, run `just required` there with the governed security
#      tools and the system npm first on PATH, then post success or failure
#      with the log's SHA-256 in the description;
#   5. retain terminal receipts and logs for verified reuse or publication recovery.
# At most one gate per tick. A PR whose head moves gets gated again because the
# status is keyed by commit.
#
# It never approves, merges, tags or waives anything. The token is the gate identity
# (GATE_RUNNER_IDENTITY), which must not be the author of the PRs it proves.
#
# Site configuration: every site specific (forge URL, credential, owners and their checkout roots,
# per-repository exceptions) is read from ${PR_GATE_CONFIG:-~/.config/jeryu/pr-gate.env} by
# pr-gate-config.sh; see ../pr-gate.env.example and ../README.md. Nothing here names a site.
#
# Slots: GATE_RUNNER_SLOT (0..N) runs independent gates side by side, one systemd instance each
# (pr-gate-runner@N). Every slot has its own lock and its own warm tree; slot 0 keeps the original
# paths. A head is claimed atomically before it is gated, so two slots never gate the same commit.
#
# Repos: by default every checkout under each owner's checkout root whose protected main requires
# <repo>/required (GATE_RUNNER_OWNERS), re-read at most every 10 minutes. GATE_RUNNER_REPOS pins an
# explicit list instead.
#
# Repos are owner/repo; a bare name means PR_GATE_PRIMARY_OWNER/. Each owner's repos run in a tree of
# every repository of that owner checked out under its checkout root (so a repository can build
# against ../<sibling>), with `just required` when their justfile has it, otherwise the repo's own
# `bash ops/ci/pr-ci.sh`. An owner whose checkout root holds one product is a single-repo tree.
#
# Usage: pr-gate-runner.sh [--repo [OWNER/]R --pr N] [--list]
#   --repo/--pr  gate this PR now, even if it already has a runner status
#   --list       print what the next tick would gate and exit
# ---------------------------------------------------------------------------
set -euo pipefail
GATE_RUNNER_SCRIPT="$(realpath -- "${BASH_SOURCE[0]}")"
# shellcheck source=ops/pr-gate/bin/pr-gate-config.sh
source "$(dirname -- "$GATE_RUNNER_SCRIPT")/pr-gate-config.sh"
pr_gate_load_config
# shellcheck source=ops/pr-gate/bin/pr-gate-state.sh
source "$(dirname -- "$GATE_RUNNER_SCRIPT")/pr-gate-state.sh"
# Hash the code that is running now, and the site configuration it read; gate inputs use this, not
# the files on disk later (see gate_inputs).
GATE_SELF_SHA256="$(sha256sum "$(dirname -- "$GATE_RUNNER_SCRIPT")/pr-gate-config.sh" \
  "$(dirname -- "$GATE_RUNNER_SCRIPT")/pr-gate-state.sh" "$GATE_RUNNER_SCRIPT")"
if [[ -f "$PR_GATE_CONFIG_FILE" && -r "$PR_GATE_CONFIG_FILE" ]]; then
  GATE_SELF_SHA256+=$'\n'"$(sha256sum <"$PR_GATE_CONFIG_FILE" | cut -c1-64)  site-config"
fi

not_configured() { printf 'pr-gate-runner: %s is not configured (set it in %s)\n' "$1" "$PR_GATE_CONFIG_FILE" >&2; exit 2; }
BASE="${JERYU_BASE:-${PR_GATE_FORGE_URL:-}}"
BASE="${BASE%/}"
[[ -n "$BASE" ]] || not_configured PR_GATE_FORGE_URL
TOKEN_FILE="$(pr_gate_path "${JERYU_TOKEN_FILE:-}")"
[[ -n "$TOKEN_FILE" ]] || not_configured JERYU_TOKEN_FILE
HOME_DIR="${GATE_RUNNER_HOME:-$HOME/gate-runner}"
REPOS="${GATE_RUNNER_REPOS:-auto}"
OWNERS="${GATE_RUNNER_OWNERS:-}"
[[ "$REPOS" != auto || -n "${OWNERS// }" ]] || not_configured "GATE_RUNNER_OWNERS (or GATE_RUNNER_REPOS)"
# The owner whose mirrors and tree keep the unsuffixed paths (mirror/, tree), and whom a bare repo
# name means. Empty: every owner is suffixed, and a bare name is refused.
PRIMARY_OWNER="${PR_GATE_PRIMARY_OWNER:-}"
SLOT="${GATE_RUNNER_SLOT:-0}"
[[ "$SLOT" =~ ^[0-9]+$ ]] || { printf 'GATE_RUNNER_SLOT must be a number, not %s\n' "$SLOT" >&2; exit 2; }
FAMILY="${GATE_RUNNER_FAMILY:-}"   # space-separated sibling repos to mirror; default: every repo of the PR's owner under its checkout root
TOOLS="${GATE_RUNNER_TOOLS:-$HOME_DIR/governed-tools/bin}"
# A native vendor tree (prebuilt third-party sources) linked at <repo>/target/native-vendor for the
# repositories in PR_GATE_NATIVE_VENDOR_REPOS, and hashed into the inputs of those in
# PR_GATE_NATIVE_VENDOR_INPUT_REPOS. Unset: no repository gets one.
VENDOR="$(pr_gate_path "${GATE_RUNNER_NATIVE_VENDOR:-}")"
VENDOR_REPOS="${PR_GATE_NATIVE_VENDOR_REPOS:-}"
VENDOR_INPUT_REPOS="${PR_GATE_NATIVE_VENDOR_INPUT_REPOS:-}"
RUNTIME_TOOLS="${GATE_RUNNER_RUNTIME_TOOLS:-$HOME_DIR/runtime-tools}"
# Owners whose family tree gets the runtime tools at <tree>/target/runtime-tools.
RUNTIME_TOOLS_OWNERS="${PR_GATE_RUNTIME_TOOLS_OWNERS:-}"
IDENTITY="${GATE_RUNNER_IDENTITY:-}"
[[ -n "$IDENTITY" ]] || not_configured GATE_RUNNER_IDENTITY
# Repositories (owner/repo, globs) whose recipe must see its physical slot path, never the private
# canonical-path mount namespace: their tests ask the host's own service manager to resolve paths.
PHYSICAL_PATH_REPOS="${PR_GATE_PHYSICAL_PATH_REPOS:-}"
# Environment variables the recipe gets, each set to the root of its family tree, for recipes that
# look for their siblings through one.
WORKER_ROOT_VARS="${PR_GATE_WORKER_ROOT_VARS:-}"
for var in $WORKER_ROOT_VARS; do
  [[ "$var" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { printf 'PR_GATE_WORKER_ROOT_VARS: %s is not a variable name\n' "$var" >&2; exit 2; }
done
# Lockfile sources, besides crates.io, that the locked-crate prefetch may fetch online: URL prefixes
# as they appear in Cargo.lock (e.g. "git+https://forge.example.test/"). Empty: crates.io only.
LOCK_SOURCES="${PR_GATE_LOCK_SOURCES:-}"
LOCK_SOURCES_ERE='registry\+https://github\.com/rust-lang/crates\.io-index|sparse\+https://index\.crates\.io/'
for prefix in $LOCK_SOURCES; do
  LOCK_SOURCES_ERE+="|$(printf '%s' "$prefix" | sed -E 's/[][\.^$*+?(){}|]/\\&/g')"
done
REGATE_SETTLE="${GATE_RUNNER_REGATE_SETTLE:-90}"
# Compile cache. Every slot shares one on-disk sccache cache, but sccache keys a Rust compile on its
# absolute paths (SCCACHE_BASEDIRS does not apply to rustc in 0.15; measured), so a crate
# built in tree-slot1 never hit for tree-slot2. So each slot >0 runs its recipe in a private mount
# namespace with its tree bound over slot 0's path (see canon_dir): every slot compiles at the same
# paths and hits every other slot's work. Each slot starts its own server on its own port inside that
# namespace, because the server reads sources through its own view of the filesystem.
# GATE_RUNNER_SCCACHE="" turns caching off; GATE_RUNNER_CANONICAL_PATH=0 turns the namespace off.
SCCACHE="${GATE_RUNNER_SCCACHE-$(command -v sccache || true)}"
# Absence is not fatal, but it used to be invisible: on one host ~/.local/bin/sccache was a dangling
# symlink to a deleted ~/.cargo/bin/sccache, `command -v` answered nothing, and every gate compiled
# uncached for an unknown time. A gate now says so once and carries cache="none" in its receipt.
# An explicit GATE_RUNNER_SCCACHE="" is a configured choice, not a missing tool, so it says nothing.
SCCACHE_MISSING=0
[[ -n "$SCCACHE" || -n "${GATE_RUNNER_SCCACHE+set}" ]] || SCCACHE_MISSING=1
SCCACHE_CACHE_DIR="${GATE_RUNNER_SCCACHE_DIR:-$HOME/.cache/sccache}"
SCCACHE_CACHE_SIZE="${GATE_RUNNER_SCCACHE_SIZE:-60G}"
SCCACHE_PORT=$((4300 + SLOT))
# Slots share the network namespace, and jeryu-web's Playwright reuses whatever server holds its
# fixed Vite port (5175), so concurrent e2e gates tested each other's builds. One port per slot.
PLAYWRIGHT_WEB_PORT=$((5300 + SLOT))
CANONICAL_PATH="${GATE_RUNNER_CANONICAL_PATH:-1}"
# A gate never pushes. The tree's hooks path points here, so an accidental push from a recipe fails
# instead of reaching the forge with this host's credentials.
HOOKS="$HOME_DIR/hooks"
MARKER="pr-gate-runner@$(hostname -s)"
# The gate needs sources, never LFS payloads. A repository that tracks model weights in LFS
# otherwise downloads them, and a missing LFS object aborts the whole tree.
export GIT_LFS_SKIP_SMUDGE=1

only_repo=""; only_pr=""; list=0
while (($#)); do case "$1" in
  --repo) only_repo="${2:?--repo needs a value}"; shift 2;;
  --pr) only_pr="${2:?--pr needs a number}"; shift 2;;
  --list) list=1; shift;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2;;
esac; done

say() { printf '[gate-runner %s slot %s] %s\n' "$(date -u +%FT%TZ)" "$SLOT" "$*"; }
die() { say "FAIL: $*"; exit 1; }
[[ -r "$TOKEN_FILE" ]] || die "token file $TOKEN_FILE is not readable"
for tool in curl jq git just flock sha256sum; do command -v "$tool" >/dev/null || die "$tool is required"; done

mkdir -p "$HOOKS"
if [[ ! -x "$HOOKS/pre-push" ]]; then
  printf '#!/bin/sh\nprintf "pr-gate-runner: a gate never pushes\\n" >&2\nexit 1\n' >"$HOOKS/pre-push"
  chmod 0755 "$HOOKS/pre-push"
fi
mkdir -p "$HOME_DIR/mirror" "$HOME_DIR/runs" "$HOME_DIR/logs" "$HOME_DIR/claims" "$HOME_DIR/cache" "$HOME_DIR/targets"
# Slot 0 keeps the original lock name, so an older single-slot install and slot 0 exclude each other.
lock_name=".lock"; ((SLOT == 0)) || lock_name=".lock-slot$SLOT"
exec 9>"$HOME_DIR/$lock_name"
flock -n 9 || { say "a gate is already running; nothing to do"; exit 0; }
# The lock lives on fd 9, and anything the gate starts inherits it unless told otherwise. A build
# daemon (sccache) spawned by `just required` detached with fd 9 open and held the lock after the
# gate had finished, so every later tick said "already running" and gated nothing. The recipe runs
# with fd 9 closed (see step 4).

# The token reaches curl through a 0600 config file, never through argv: anyone with a shell on
# this host can read /proc/<pid>/cmdline while a gate runs, and `-H "Authorization: Bearer $(cat
# ...)"` put the credential there on every request. Reported in review, 2026-09-15.
AUTH_CONFIG="$(mktemp "${TMPDIR:-/tmp}/gate-runner-auth.XXXXXX")"
chmod 0600 "$AUTH_CONFIG"
gate_receipt="" gate_worker=""
trap gate_exit EXIT
trap 'gate_signal TERM 143' TERM
trap 'gate_signal INT 130' INT
trap 'gate_signal HUP 129' HUP
printf 'header = "Authorization: Bearer %s"\n' "$(cat "$TOKEN_FILE")" >"$AUTH_CONFIG"

# Arguments are built as an array: an unquoted "${3:+-H '...'}" word-splits the header
# into pieces, and the forge then answers as if the token were bad.
# It sets the globals $body and $code rather than printing: `x="$(api ...)"` would run it
# in a subshell, and $code would never reach the caller.
api() { # method path [json]
  local args=(--silent --show-error --max-time 60 -X "$1"
    --config "$AUTH_CONFIG" -H 'Accept: application/json')
  [[ -z "${3:-}" ]] || args+=(-H 'Content-Type: application/json' --data "$3")
  local out
  out="$(curl "${args[@]}" -w '\n%{http_code}' "$BASE$2")" || out=$'\n000'
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
}

post_status() { # owner repo sha state description
  api POST "/repos/$1/$2/statuses/$3" "$(jq -n --arg s "$4" --arg c "$(gate_required_context "$1" "$2")" \
    --arg d "$5" '{state: $s, context: $c, description: $d}')"
  [[ "$code" == 201 ]] || die "posting $1/$2 $(gate_required_context "$1" "$2")=$4 on $3 answered $code: $body"
}

# Heartbeats tell jeryu's /fleet what each slot is doing: the gate it is running and the last gate
# it finished. They are best-effort and never fail a gate. A forge that predates the route answers
# with the web app's HTML, so only a JSON refusal is worth a log line.
RUNNER_HOST="$(hostname -s)"
LAST_GATE="$HOME_DIR/cache/slot-$SLOT-last.json"
# The heartbeat also says what code this runner is (gate_runner_code) and what it evaluates with
# (gate_runner_tools). A forge that predates either field refuses the whole heartbeat with 422, so a
# 422 is retried once without tools (keeping code), and if that is refused too, once without code;
# each is logged once, and the rest of this run sends neither refused field.
HEARTBEAT_CODE="$(gate_runner_code "$HOME_DIR")"
HEARTBEAT_TOOLS="$(gate_runner_tools "$HOME_DIR")"
heartbeat() { # [current-gate-json]
  local current="${1:-null}" last="null" payload
  [[ -s "$LAST_GATE" ]] && jq -e . "$LAST_GATE" >/dev/null 2>&1 && last="$(cat "$LAST_GATE")"
  payload="$(jq -nc --arg id "$RUNNER_HOST/slot$SLOT" \
    --arg host "$RUNNER_HOST" --argjson slot "$SLOT" --argjson current "$current" --argjson last "$last" \
    '{runnerId: $id, host: $host, slot: $slot, labels: ["pr-gate"], current: $current, last: $last}')"
  api POST "/api/v1/runners/heartbeat" "$(gate_heartbeat_with "$payload" "$HEARTBEAT_CODE" "$HEARTBEAT_TOOLS")"
  if [[ "$code" == 422 && -n "$HEARTBEAT_TOOLS" ]]; then
    say "heartbeat tools refused (422); retrying without them"
    HEARTBEAT_TOOLS=""
    api POST "/api/v1/runners/heartbeat" "$(gate_heartbeat_with "$payload" "$HEARTBEAT_CODE" "")"
  fi
  if [[ "$code" == 422 && -n "$HEARTBEAT_CODE" ]]; then
    say "heartbeat code refused (422); retrying without it"
    HEARTBEAT_CODE=""
    api POST "/api/v1/runners/heartbeat" "$payload"
  fi
  if ! jq -e '.accepted == true' <<<"$body" >/dev/null 2>&1 && jq -e . <<<"$body" >/dev/null 2>&1; then
    say "heartbeat refused ($code): $(jq -c '.message // .' <<<"$body")"
  fi
  return 0
}

# A bare name without a primary owner is refused before any qualify (see below), never guessed.
qualify() { [[ "$1" == */* || -z "$PRIMARY_OWNER" ]] && printf '%s' "$1" || printf '%s/%s' "$PRIMARY_OWNER" "$1"; }
# Where each owner's canonical checkouts live (used only to discover the family): its entry in
# PR_GATE_CHECKOUT_ROOTS ("owner=path ..."), else PR_GATE_CHECKOUT_ROOT_PATTERN with {owner} replaced;
# a relative path is under $HOME. Where its mirrors and persistent tree go: the primary owner keeps
# the unsuffixed paths so its warm tree survives.
split_root() {
  local root
  root="$(pr_gate_lookup "${PR_GATE_CHECKOUT_ROOTS:-}" "$1")" \
    || root="${PR_GATE_CHECKOUT_ROOT_PATTERN:-}"
  [[ -n "$root" ]] || { say "no checkout root for owner $1 (PR_GATE_CHECKOUT_ROOTS or PR_GATE_CHECKOUT_ROOT_PATTERN)" >&2; return 1; }
  pr_gate_path "${root//\{owner\}/$1}"
}
mirror_dir() { [[ -n "$PRIMARY_OWNER" && "$1" == "$PRIMARY_OWNER" ]] && printf '%s' "$HOME_DIR/mirror" || printf '%s' "$HOME_DIR/mirror/$1"; }
# Slot 0's tree path; every slot's recipe sees its own tree at this path (see SCCACHE above).
canon_dir() { [[ -n "$PRIMARY_OWNER" && "$1" == "$PRIMARY_OWNER" ]] && printf '%s' "$HOME_DIR/tree" || printf '%s' "$HOME_DIR/tree-$1"; }
tree_dir() {
  local base; base="$(canon_dir "$1")"
  ((SLOT == 0)) && printf '%s' "$base" || printf '%s' "$base-slot$SLOT"
}

# Every repo of the configured owners whose protected main requires <repo>/required. The answer is
# cached for ten minutes: slots tick every minute, and protection changes rarely.
discover_repos() {
  local owner cache d n url root
  for owner in $OWNERS; do
    cache="$HOME_DIR/cache/protected-$owner"
    if [[ ! -s "$cache" || -n "$(find "$cache" -mmin +10 2>/dev/null)" ]]; then
      : >"$cache.tmp.$SLOT"
      root="$(split_root "$owner")" || continue
      for d in "$root"/*/; do
        n="$(basename "$d")"
        url="$(git -C "$d" remote get-url origin 2>/dev/null || true)"
        [[ "$url" == "$BASE/git/$owner/$n.git" ]] || continue
        api GET "/api/v3/repos/$owner/$n/branches/main/protection"
        # 404 is an unprotected main. Anything else means this identity cannot see the repo, which
        # would leave a protected repo ungated without a word, so say it on every refresh.
        if [[ "$code" != 200 ]]; then
          [[ "$code" == 404 ]] || say "cannot read $owner/$n protection ($code); grant $IDENTITY access or it stays ungated" >&2
          continue
        fi
        jq -e --arg c "$(gate_required_context "$owner" "$n")" '(.required_status_checks.contexts // []) | index($c) != null' \
          <<<"$body" >/dev/null 2>&1 && printf '%s/%s\n' "$owner" "$n" >>"$cache.tmp.$SLOT"
      done
      mv -f "$cache.tmp.$SLOT" "$cache"
    fi
    cat "$cache"
  done
}
[[ "$REPOS" != auto ]] || REPOS="$(discover_repos | tr '\n' ' ')"
for q in $REPOS $only_repo; do
  [[ "$q" == */* || -n "$PRIMARY_OWNER" ]] || die "repository $q has no owner and PR_GATE_PRIMARY_OWNER is not configured"
done

# 1-2. choose the next head
candidates=()
[[ -z "$only_repo" ]] || only_repo="$(qualify "$only_repo")"
for qualified in $REPOS; do
  qualified="$(qualify "$qualified")"
  [[ -z "$only_repo" || "$qualified" == "$only_repo" ]] || continue
  owner="${qualified%%/*}" repo="${qualified#*/}"
  api GET "/api/v1/repos/$owner%2F$repo/pulls?state=open"
  rows="$body"
  [[ "$code" == 200 ]] || { say "listing $owner/$repo PRs answered $code; skipping it"; continue; }
  while IFS=$'\t' read -r number sha; do
    [[ -n "$number" ]] || continue
    [[ -z "$only_pr" || "$number" == "$only_pr" ]] || continue
    # The v1 list rows carry an empty head.ref, so author and branch come from v3 per PR.
    api GET "/api/v3/repos/$owner/$repo/pulls/$number"
    author="$(jq -r '.user.login // ""' <<<"$body")"
    head_ref="$(jq -r '.head.ref // ""' <<<"$body")"
    [[ "$code" == 200 && -n "$author" ]] \
      || { say "cannot read $owner/$repo#$number's author ($code); skipping rather than guessing"; continue; }
    # Never prove this runner's own work. A proof is only worth the independence of whoever
    # produced it, and gating a head this identity pushed makes the runner both author and
    # witness. --repo/--pr does not override this; it is not a re-run, it is a role.
    # Reported in review, 2026-09-15.
    if [[ "$author" == "$IDENTITY" || "$head_ref" == "$IDENTITY/"* ]]; then
      say "skipping $owner/$repo#$number: head is $IDENTITY's own work, which this runner must not prove"
      continue
    fi
    # A historical marker is neither a reusable success nor a live claim. The
    # durable receipt, full input identity and current publication decide below.
    [[ "$sha" == "$(jq -r '.head.sha // ""' <<<"$body")" ]] || continue
    candidates+=("$owner $repo $number $sha -")
  done < <(jq -r '.items[]? | [.number, .head_sha] | @tsv' <<<"$rows" | sort -n)
done
# Merge queue (jeryu-deploy docs/merge-queue.md). The forge replays an approved PR onto its base tip as
# refs/queue/<base>/<n> and lands that exact commit by compare-and-swap once its required context is
# green, so a PR that fell behind main needs nobody to rebase it. The runner gates queue_sha exactly as
# it gates a PR head -- same recipe, tree, context and identity -- fetched through queue_ref. Entries go
# first: each is one gate from landing. A candidate's fifth field is its queue ref, "-" for a PR head.
queued=()
gated=" $(for q in $REPOS; do qualify "$q"; printf ' '; done)"
if [[ -z "$only_pr" ]]; then
  api GET "/api/v1/merge-queue?state=building"
  if [[ "$code" == 200 ]]; then
    queue_rows="$body"
    while IFS=$'\t' read -r qrepo number sha qref; do
      if ! [[ "$qrepo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$number" =~ ^[0-9]+$ && "$sha" =~ ^[0-9a-f]{40}$ \
          && "$qref" =~ ^refs/queue/[A-Za-z0-9._/-]+$ && "$qref" != *..* ]]; then
        say "ignoring a malformed merge-queue entry: $qrepo#$number"; continue
      fi
      [[ "$gated" == *" $qrepo "* ]] || continue
      [[ -z "$only_repo" || "$qrepo" == "$only_repo" ]] || continue
      owner="${qrepo%%/*}" repo="${qrepo#*/}"
      api GET "/api/v3/repos/$owner/$repo/pulls/$number"
      author="$(jq -r '.user.login // ""' <<<"$body")" head_ref="$(jq -r '.head.ref // ""' <<<"$body")"
      [[ "$code" == 200 && -n "$author" ]] || { say "cannot read queued $qrepo#$number's author ($code); skipping"; continue; }
      if [[ "$author" == "$IDENTITY" || "$head_ref" == "$IDENTITY/"* ]]; then
        say "skipping queued $qrepo#$number: $IDENTITY's own work, which this runner must not prove"; continue
      fi
      queued+=("$owner $repo $number $sha $qref")
    done < <(jq -r '.entries[]? | [.repo, (.number|tostring), .queue_sha, .queue_ref] | @tsv' <<<"$queue_rows")
  else
    say "merge queue answered $code; gating PR heads only this tick"
  fi
fi
# Heads never gated go first after the queue. A sibling's main moving invalidates every open result in
# the family, and re-proving those in PR order put each new head behind all of them, one tree
# preparation at a time. Only the order changes; every head is still decided exactly as before.
# Those re-gates are automatic, and bounded by coalescing (see gate_regate_settling): while the family's
# mains moved within GATE_RUNNER_REGATE_SETTLE seconds (default 90), an already-gated head waits for the
# burst to end. --repo/--pr is never deferred.
fresh=() seen_before=()
for candidate in "${candidates[@]}"; do
  read -r owner repo number sha qref <<<"$candidate"
  if [[ ! -d "$HOME_DIR/attempts/$owner-$repo-$sha" ]]; then fresh+=("$candidate"); continue; fi
  if [[ -z "$only_pr" ]] && gate_regate_settling "$HOME_DIR/cache/mains-$owner" "$REGATE_SETTLE"; then
    say "deferring re-gate of $owner/$repo#$number: $owner mains moved within ${REGATE_SETTLE}s"; continue
  fi
  seen_before+=("$candidate")
done
candidates=("${queued[@]}" "${fresh[@]}" "${seen_before[@]}")

if ((${#candidates[@]} == 0)); then ((list)) || heartbeat; say "no PR head needs gating"; exit 0; fi
if ((list)); then printf '%s\n' "${candidates[@]}"; exit 0; fi
# FD7 protects the shared repository target; FD6 protects the full-head journal.
# FD9 protects this slot's source tree. The timeout supervisor retains all three
# through parent death; the recipe closes them before it can start cache daemons.
# The slot's cache daemon is started by the worker itself, after it has closed all three.
for candidate in "${candidates[@]}"; do
read -r owner repo number sha qref <<<"$candidate"
[[ "$owner" =~ ^[A-Za-z0-9._-]+$ && "$repo" =~ ^[A-Za-z0-9._-]+$ && "$sha" =~ ^[0-9a-f]{40}$ \
   && ( "$qref" == - || "$qref" =~ ^refs/queue/[A-Za-z0-9._/-]+$ ) ]] \
  || die "invalid repository or head in dispatch"
if [[ -d "$HOME_DIR/claims/$owner-$repo-$sha" ]]; then
  say "recovery required: retained legacy claim for $owner/$repo@$sha; reconcile its worker before admission"
  continue
fi
# The repository lock keeps two slots out of one shared build directory. A repository that builds in
# its own slot tree (every one not in GATE_RUNNER_SHARED_TARGETS) has nothing to protect, and taking
# the lock anyway ran two PRs of one repository strictly one after the other.
shares_target=0
for pattern in ${GATE_RUNNER_SHARED_TARGETS:-}; do
  # shellcheck disable=SC2053
  if [[ "$owner/$repo" == $pattern || "$repo" == $pattern ]]; then shares_target=1; break; fi
done
if ((shares_target)); then
  mkdir -p "$HOME_DIR/targets/$owner"
  exec 7>"$HOME_DIR/targets/$owner/$repo.lock"
  flock -n 7 || { exec 7>&-; continue; }
fi
gate_lock "$owner-$repo-$sha" || { exec 7>&-; continue; }
: "${gate_key_dir:?}"
# Recovery belongs to this head, not to the tick: a head whose evidence cannot be published (say the
# forge refuses this identity there) must not stop every other repository from being gated.
if ! gate_recover; then
  say "recovery required for $owner/$repo@$sha: unpublished terminal evidence; leaving it for the next tick"
  # gate_recover clears gate_receipt only when it succeeds. Clear it here too, or the EXIT trap would
  # publish this head's retained evidence while another commit is being gated.
  gate_receipt=""
  exec 6>&-; exec 7>&-
  continue
fi
say "preparing $owner/$repo#$number at $sha${qref:+$([[ "$qref" == - ]] || printf ' (merge queue %s)' "$qref")}"

# 3. clean tree
family="$FAMILY"
if [[ -z "$family" ]]; then
  root="$(split_root "$owner")" || die "cannot discover the $owner family"
  for d in "$root"/*/; do
    n="$(basename "$d")"
    url="$(git -C "$d" remote get-url origin 2>/dev/null || true)"
    [[ "$url" == "$BASE/git/$owner/$n.git" ]] && family+=" $n"
  done
fi
mirrors="$(mirror_dir "$owner")"
mkdir -p "$mirrors"
for n in $family $repo; do
  m="$mirrors/$n.git"
  # Slots share mirrors; one writer at a time per mirror.
  exec 8>"$m.lock"; flock 8
  # Only one mirror failure is tolerated, and only for a sibling: the repository genuinely has no
  # canonical main, so it cannot be a dependency of anything (a repository that carries only its
  # scaffold branch, and treating that as fatal killed every gate of its family here). The absence is
  # proven with ls-remote --exit-code, which answers 2 for "no such ref". Anything else -- an
  # unreachable forge, a refused credential, a corrupt mirror -- stays fatal, because a gate that
  # silently builds against a stale or missing sibling proves nothing.
  mirror_ok=1
  if [[ -d "$m" ]]; then
    git -C "$m" fetch --quiet --prune origin '+refs/heads/main:refs/heads/main' || mirror_ok=0
  else
    git clone --quiet --bare --single-branch --branch main "$BASE/git/$owner/$n.git" "$m" || {
      mirror_ok=0
      rm -rf -- "$m"   # a partial clone would take the fetch path next time and fail there
    }
  fi
  if ((mirror_ok == 0)); then
    probe=0
    git ls-remote --exit-code --heads "$BASE/git/$owner/$n.git" refs/heads/main >/dev/null 2>&1 || probe=$?
    ((probe == 2)) || die "cannot mirror canonical main for $owner/$n (ls-remote answered $probe)"
    if [[ "$n" == "$repo" ]]; then
      post_status "$owner" "$repo" "$sha" failure "no canonical main to gate against ($MARKER)"
      say "$owner/$repo has no canonical main; its own head cannot be gated"
      flock -u 8; exec 6>&-; exec 7>&-
      continue 2
    fi
    # Drop the mirror as well. A repository whose main was deleted upstream would otherwise keep an
    # older main here, and step 3 would check the sibling out from it: a phantom main in the tree
    # while this line says the tree lacks it. With no mirror, step 3 skips the sibling.
    # Check the current owner's persistent tree below, after selecting its path.
    # An inherited or previous candidate's $run is not cleanup authority.
    rm -rf -- "$m"
    say "$owner/$n has no canonical main; the tree will lack it"
    flock -u 8; continue
  fi
  flock -u 8
done
exec 8>&-
gate_record_mains "$HOME_DIR/cache/mains-$owner" "$mirrors" $family $repo || say "could not record $owner mains"

# One persistent family tree, reset to exact commits for every gate. Build output is the only
# thing kept between gates: every repo is detached at its commit, hard-reset, and cleaned of all
# untracked and ignored files EXCEPT target/ and node_modules/. Sources are therefore exactly the
# commits under test; only compiled artifacts carry over, and cargo and pnpm verify those against
# the sources. A fresh clone per gate made every run a cold build -- one web repository took ~25
# minutes rebuilding a 16 GB target/ that the previous gate had already produced.
# One gate at a time holds the lock, so one tree is enough. A red gate's diagnostics stay in the
# tree until the next gate starts; its log is kept regardless.
run="$(tree_dir "$owner")"
mkdir -p "$run"
sync_repo() { # name commit-ish
  local dir="$run/$1"
  if [[ ! -d "$dir/.git" ]]; then
    rm -rf "$dir"
    git clone --quiet --no-local --no-checkout "$mirrors/$1.git" "$dir"
  fi
  # Hosted origin is source authority for every family. Cached objects have a
  # distinct remote; never weaken source-authority tests to accept a local origin.
  git -C "$dir" config --replace-all remote.origin.url "$BASE/git/$owner/$1.git"
  # Both URLs are the hosted repository, because some repositories' hosted-source-authority tests
  # require a canonical push URL as well; a refusing push URL failed every one of their gates. Instead the tree
  # gets a runner-owned pre-push hook that refuses. It is defence in depth, not a boundary: the recipe
  # runs as the user that owns the credential files and can undo this config, so only the
  # credential-isolating sandbox actually denies a gate the ability to push.
  # No pushurl key at all. Some repositories require "git remote get-url --push origin" to be the
  # canonical hosted URL, and others refuse the key's very existence ("local Git configuration key is
  # forbidden for branch publication: remote.pushurl"). With no key, git answers the fetch URL, which
  # is canonical, and both are satisfied. The pre-push hook below is what refuses an actual push.
  git -C "$dir" config --unset-all remote.origin.pushurl 2>/dev/null || true
  git -C "$dir" config --replace-all core.hooksPath "$HOOKS"
  if git -C "$dir" remote get-url cache-mirror >/dev/null 2>&1; then
    git -C "$dir" remote set-url cache-mirror "$mirrors/$1.git"
  else
    git -C "$dir" remote add cache-mirror "$mirrors/$1.git"
  fi
  # origin/main moves with it. The jankurai renderer resolves "protected main" from origin/main
  # and refuses when that commit's tool-manifest.toml differs from the checked-out one, so a
  # tree whose origin/main was left at the day it was first cloned fails every repo's pin drift
  # check as soon as jeryu-tool's manifest changes ("tool-manifest.toml must land on protected
  # jeryu-tool main"). The mirror is the forge's protected main, so both refs name the same commit.
  git -C "$dir" fetch --quiet cache-mirror '+refs/heads/main:refs/remotes/mirror/main' \
    '+refs/heads/main:refs/remotes/origin/main'
  git -C "$dir" checkout --quiet --force --detach "$2"
  git -C "$dir" reset --quiet --hard "$2"
  git -C "$dir" clean --quiet -ffdx -e target/ -e node_modules/
  # Every slot's checkout of a repo builds into one shared target directory (step 3), and cargo
  # decides freshness from mtimes. A tracked file this checkout left untouched can be older than
  # another tree's build of different content, and cargo then reuses that build: the gate would
  # test a commit other than the one it reports (seen on a data repository, 2026-09-17). Stamp
  # every tracked file now; -h stamps symlinks themselves, never what they point at.
  git -C "$dir" ls-files -z | (cd "$dir" && xargs -0r touch -h -c --)
}
for n in $family; do
  [[ "$n" == "$repo" ]] && continue
  if [[ ! -d "$mirrors/$n.git" ]]; then
    # A missing canonical main may omit a fresh sibling, but cannot authorize
    # the persistent slot's old source. Leave it intact for explicit recovery.
    [[ ! -e "$run/$n" && ! -L "$run/$n" ]] \
      || die "stale sibling checkout without canonical main: $owner/$n; worker tree recovery required"
    continue
  fi
  sync_repo "$n" mirror/main
done
[[ -d "$run/$repo/.git" ]] || sync_repo "$repo" mirror/main
# The tree must hold exactly this gate's family and repository. A slot tree persists, and a repository
# synced for an earlier gate (a nested product's repo gated through another owner's tree, say) stayed
# in it; gate_inputs fingerprints every checkout present, so the same head had a different identity on
# every slot. On 2026-09-18 one web PR passed 12 times in an hour as slots 1, 4 and 5 disagreed about
# such repositories, each pass followed by a fresh `pending` that kept the PR unmergeable. Anything
# else is moved aside -- it is a disposable checkout of a mirror, kept only until the next move.
for n in $(gate_detach_strays "$run" "$HOME_DIR/detached/slot$SLOT" $family $repo); do
  say "moved $owner/$n out of the slot tree: not in this gate's family"
done
mapfile -t evidence < <(gate_evidence_for "$owner")
if ((${#evidence[@]})); then
  while read -r line; do say "$line"; done < <(gate_mirror_evidence "$run" "$BASE" "${evidence[@]}")
fi
if [[ "$qref" == - ]]; then
  git -C "$run/$repo" fetch --quiet "$BASE/git/$owner/$repo.git" "$sha"
else
  # A queue commit is fetched by its advertised ref, and must still be the entry's exact sha: the forge
  # rebuilds an entry on a fresh commit when main moves, and a rebuilt entry is gated on its own tick.
  git -C "$run/$repo" fetch --quiet "$BASE/git/$owner/$repo.git" "+$qref:refs/gate/queue"
  if [[ "$(git -C "$run/$repo" rev-parse refs/gate/queue)" != "$sha" ]]; then
    say "merge-queue entry $owner/$repo#$number moved on from $sha; leaving it for the next tick"
    exec 6>&-; exec 7>&-
    continue
  fi
fi
sync_repo "$repo" "$sha"
[[ "$(git -C "$run/$repo" rev-parse HEAD)" == "$sha" ]] || die "could not check out $sha"
[[ -z "$(git -C "$run/$repo" status --porcelain --ignored=no)" ]] || die "$repo is not clean at $sha"
# Some family integrity tests need governed runtime fixtures (a pinned typesetter, say) at the family
# root's target/, the same shape the release host has. Without them the whole recipe fails on a
# missing tool and says nothing about the commit under test. PR_GATE_RUNTIME_TOOLS_OWNERS names them.
if pr_gate_listed "$RUNTIME_TOOLS_OWNERS" "$owner" && [[ -d "$RUNTIME_TOOLS" ]]; then
  mkdir -p "$run/target" && ln -sfn "$RUNTIME_TOOLS" "$run/target/runtime-tools"
fi
# One build directory per repo, shared by every slot: <repo>/target is a symlink to
# targets/<owner>/<repo>. Cargo reuses artifacts across checkouts at different paths when the target
# directory is the same (measured on a gate host: a second slot's build recompiled 2 of 241
# crates, against all 241 with its own target), whereas sccache keys on the build path and missed
# every crate. Recipes still find their binaries at <repo>/target. The repo lock taken at claim time
# keeps two gates of the same repo out of one target directory.
# Some repositories refuse a symlinked component anywhere under target/ as a containment violation
# (an ops/ci/lib.sh ci_validate_dir_fd check), so for them the symlink is a guaranteed red gate that
# says nothing about the commit. They keep a real target directory in their own tree and lose the
# shared warm build. Matched against "<owner>/<repo>" and against "<repo>", as globs.
# Sharing one build directory between slot checkouts is OPT IN, because the family's own conventions
# refuse it. A shared target is reached through a symlink at <repo>/target, and fourteen gated
# repositories failed on that link rather than on the commit: through ops/ci/lib.sh,
# ops/ci/artifact_support.sh ("proof output path is not a physical directory"), ops/ci/proof-routing.sh,
# fast-coverage contract tests, cargo-lock closure tests and ci_validate_dir_fd. A repository that
# measures coverage with cargo-llvm-cov, which reports over every object and profile present, silently
# merges other commits' builds in a shared directory (one measured 31.80% over 49,954 lines against
# 87.70% over 18,098 in its own tree).
#
# So: every repository gets a real target directory inside its own slot tree unless it is named in
# GATE_RUNNER_SHARED_TARGETS (globs against "<owner>/<repo>" and "<repo>"). Opting one in is safe only
# where its recipe tolerates a symlinked target and measures nothing from the directory. The cost of
# the default is a colder build; the benefit is that a gate result is about the commit.
SHARED_TARGETS="${GATE_RUNNER_SHARED_TARGETS:-}"
shared_target=""
for pattern in $SHARED_TARGETS; do
  # shellcheck disable=SC2053
  if [[ "$owner/$repo" == $pattern || "$repo" == $pattern ]]; then
    shared_target="$HOME_DIR/targets/$owner/$repo"; break
  fi
done
if [[ -z "$shared_target" ]]; then
  rm -rf "$run/$repo/target"
  mkdir -p "$run/$repo/target"
  say "$owner/$repo builds in its own clean tree (not in GATE_RUNNER_SHARED_TARGETS)"
elif [[ -d "$run/$repo/target" && ! -L "$run/$repo/target" ]]; then
  if [[ ! -e "$shared_target" ]]; then
    mv "$run/$repo/target" "$shared_target"   # first gate of this repo keeps its warm build
  else
    rm -rf "$run/$repo/target"                # a duplicate of the shared build
  fi
fi
if [[ -n "$shared_target" ]]; then
  mkdir -p "$shared_target"
  ln -sfn "$shared_target" "$run/$repo/target"
fi
# A directory-only .gitignore pattern does not ignore a symlink. Exclude this
# runner-owned output link locally; tracked source changes remain visible.
exclude=$(git -C "$run/$repo" rev-parse --absolute-git-dir)/info/exclude
grep -qxF /target "$exclude" || printf '/target\n' >>"$exclude"
if [[ -n "$VENDOR" && -d "$VENDOR" ]] && pr_gate_listed "$VENDOR_REPOS" "$repo" "$owner/$repo"; then
  mkdir -p "$run/$repo/target" && ln -sfn "$VENDOR" "$run/$repo/target/native-vendor"
fi

# 4. gate
# Shared targets retain each repository's expected <repo>/target path. The
# repository lock serializes writers across slots, while unrelated repos build
# independently. A shared sccache can additionally reuse compiler outputs.
# The gate command remains the repository's own recipe. No log text can change
# its conclusion: a successful negative test is still a successful process.
if (cd "$run/$repo" && just --summary 2>/dev/null | tr ' ' '\n' | grep -qx required); then
  recipe=(just required) recipe_name="just required"
elif [[ -f "$run/$repo/ops/ci/pr-ci.sh" ]]; then
  recipe=(bash ops/ci/pr-ci.sh) recipe_name="ops/ci/pr-ci.sh"
else
  # Say so on the PR and move on. Dying here left no status and stopped the whole tick, so one
  # recipe-less head blocked every other candidate, tick after tick.
  post_status "$owner" "$repo" "$sha" failure "no gate: neither just required nor ops/ci/pr-ci.sh at this head ($MARKER)"
  say "$owner/$repo at $sha has neither a required recipe nor ops/ci/pr-ci.sh"
  exec 6>&-; exec 7>&-
  continue
fi
identity=$(mktemp "$HOME_DIR/cache/inputs-$SLOT.XXXXXXXX")
status_snapshot=$(mktemp "$HOME_DIR/cache/status-$SLOT.XXXXXXXX")
PATH="$TOOLS:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" gate_inputs "$identity"
api GET "/repos/$owner/$repo/commits/$sha/status"
[[ "$code" == 200 ]] || die "cannot verify current status for $owner/$repo@$sha ($code)"
printf '%s\n' "$body" >"$status_snapshot"
retry=0; [[ -z "$only_pr" ]] || retry=1
gate_decision "$identity" "$retry" "$status_snapshot"
case "${gate_action:?}" in
  reuse|hold)
    say "$gate_action $owner/$repo@$sha: identical verified inputs (a failure re-runs only with --repo <o>/<r> --pr <n>, or changed inputs)"
    rm -f -- "$identity" "$status_snapshot"
    exec 6>&-; exec 7>&-
    continue;;
  republish)
    id=$(jq -r '.id' "$gate_key_dir/last-result.json")
    gate_receipt="$gate_key_dir/$id/receipt.json"
    gate_publish || die "publication recovery still rejected; retained $gate_receipt"
    gate_receipt=""
    rm -f -- "$identity" "$status_snapshot"
    exec 6>&-; exec 7>&-
    continue;;
esac
# A head moving during preparation must not run under the earlier admission. A queue commit is still
# admitted only while its entry is building at the same sha.
if [[ "$qref" == - ]]; then
  api GET "/api/v3/repos/$owner/$repo/pulls/$number"
  [[ "$code" == 200 ]] || die "cannot refresh PR before admission ($code)"
  admitted=0
  [[ "$(jq -r '.head.sha' <<<"$body")" == "$sha" && "$(jq -r '.state' <<<"$body")" == open ]] && admitted=1
else
  api GET "/api/v1/merge-queue?state=building"
  [[ "$code" == 200 ]] || die "cannot refresh the merge queue before admission ($code)"
  admitted=0
  jq -e --arg r "$owner/$repo" --argjson n "$number" --arg s "$sha" \
    'any(.entries[]?; .repo == $r and (.number|tonumber) == $n and .queue_sha == $s)' <<<"$body" >/dev/null && admitted=1
fi
if ((admitted == 0)); then
  say "head changed or PR closed before admission (or its queue entry moved): $owner/$repo#$number"
  rm -f -- "$identity" "$status_snapshot"
  exec 6>&-; exec 7>&-
  continue
fi
gate_begin "$identity"
: "${gate_attempt_dir:?}"
# Re-verifying a head whose newest required status is this runner's own success does not post
# `pending` over it: merge readiness reads the newest status, so each re-verification made a passing PR
# unmergeable until it finished (jeryu-web#23: 12 passes in an hour, ~15s green windows). The success
# stays until this attempt's conclusion replaces it -- a failure is still published the moment it exists.
keep_green=0
gate_newest_is_own_success "$status_snapshot" && keep_green=1
rm -f -- "$identity" "$status_snapshot"
log="$gate_attempt_dir/build.log"
if ((keep_green)); then
  say "re-verifying $owner/$repo@$sha without pending: its newest $(gate_required_context "$owner" "$repo") is this runner's success"
else
  post_status "$owner" "$repo" "$sha" pending "operator-unsealed $recipe_name running on $MARKER; attempt $(jq -r '.id' "$gate_receipt")"
fi
gate_update '.phase="running"'
started_at="$(date -u +%FT%TZ)" started_s="$(date +%s)"
heartbeat "$(jq -nc --arg repo "$owner/$repo" --argjson pr "$number" --arg sha "$sha" \
  --arg recipe "$recipe_name" --arg at "$started_at" \
  '{repo:$repo,pr:$pr,sha:$sha,recipe:$recipe,startedAt:$at}')"
# Remove inherited credential variables. This operator path is still not a
# sealed worker: installed credential/UID isolation belongs to SplitOps promotion.
# A slot >0 binds its tree over slot 0's path in a private mount namespace (root only for the mount;
# setpriv drops back to this user before anything of the recipe runs). sudo keeps our real uid, so
# the process-group kill in gate cleanup still reaches it and it relays the signal to the recipe.
worker_root="$run" enter=()
if pr_gate_listed "$PHYSICAL_PATH_REPOS" "$owner/$repo"; then
  # Its privileged boundary tests ask the host systemd manager to resolve paths.
  # A private bind alias exists only inside this worker's mount namespace.
  say "$owner/$repo uses its physical slot path for host-managed boundary tests"
elif ((CANONICAL_PATH)) && [[ "$run" != "$(canon_dir "$owner")" ]]; then
  if sudo -n unshare --mount --propagation private -- true 2>/dev/null; then
    worker_root="$(canon_dir "$owner")"
    mkdir -p "$worker_root"
    # shellcheck disable=SC2016  # expanded by the inner sh
    enter=(sudo -n unshare --mount --propagation private -- sh -c \
      'mount --bind -- "$1" "$2" && u=$3 g=$4 && shift 4 && exec setpriv --reuid="$u" --regid="$g" --init-groups -- "$@"' \
      pr-gate-ns "$run" "$worker_root" "$(id -u)" "$(id -g)")
  else
    say "no passwordless mount namespace; $owner/$repo builds at its slot path and misses other slots' cache"
  fi
fi
sccache_env=(SCCACHE_SERVER_PORT="$SCCACHE_PORT" SCCACHE_DIR="$SCCACHE_CACHE_DIR" SCCACHE_CACHE_SIZE="$SCCACHE_CACHE_SIZE")
if [[ -n "$SCCACHE" ]]; then
  # A fresh server per gate, started in the same view of the sources the recipe gets: an older one
  # may hold another namespace. It must not inherit the head, target or slot lock.
  # shellcheck disable=SC2016  # expanded by the inner sh
  # The server runs the compiles, so it takes the recipe's idle I/O class (see the worker below).
  "${enter[@]}" env -i HOME="$HOME" PATH="$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" "${sccache_env[@]}" \
    ionice -c 3 sh -c '"$0" --stop-server; "$0" --start-server' "$SCCACHE" 6>&- 7>&- 9>&- >/dev/null 2>&1 \
    || { say "sccache did not start on port $SCCACHE_PORT; $owner/$repo builds uncached"; SCCACHE=""; }
elif ((SCCACHE_MISSING)); then
  say "sccache not found on PATH; $owner/$repo builds uncached"
fi
# What this attempt actually compiled with, for the receipt, the event log and the Activity feed.
gate_update --arg cache "$([[ -n "$SCCACHE" ]] && printf sccache || printf none)" '.cache=$cache'
# Recipes build offline (`cargo ... --offline`) against the shared ~/.cargo registry, sibling and nested
# workspaces included (a gate may run a sibling's renderer or build a nested validator). When a family
# main bumped a Cargo.lock nothing downloaded the new crates, so every such gate failed until someone
# fetched them by hand. Before the recipe, every tracked Cargo.lock of the PR's repo and the root Cargo.lock
# of each sibling (not vendored crates or test fixtures; each distinct lock once) is checked offline;
# only a missing-from-registry answer fetches online, pinned by the lock's checksums.
# It runs exactly as the recipe does -- same namespace entry, `env -i` environment, idle I/O, no runner
# descriptors -- because a PR's own .cargo/config.toml steers Cargo, and must never do so with more
# than the recipe gets. No "already fetched" memory: a cleaned registry is always re-checked.
# The registry is a cache, not a gate input; the recipe itself stays offline.
# shellcheck disable=SC2016  # expanded by the worker's bash
prefetch='exec 6>&- 7>&- 9>&-
neutral=$(mktemp -d) || exit 1
trap "rm -rf -- \"\$neutral\"" EXIT
declare -A seen
for repo_dir in "$1"/*/; do
  [ -d "$repo_dir/.git" ] || continue
  # The PR'"'"'s own repo: every lockfile; a sibling: its root lockfile. Two siblings carried ~500
  # archived lockfiles each, and checking all 1048 took 98s a gate.
  if [ "$(basename "$repo_dir")" = "$2" ]; then
    set -- "$1" "$2" "$3" Cargo.lock "*/Cargo.lock"
  else
    set -- "$1" "$2" "$3" Cargo.lock
  fi
  while IFS= read -r -d "" lock; do
    dir="$repo_dir${lock%Cargo.lock}"
    digest=$(sha256sum "$dir/Cargo.lock" | cut -c1-64)
    [ -z "${seen[$digest]:-}" ] || continue
    seen[$digest]=1
    out=$(cd "$dir" && cargo fetch --locked --offline 2>&1) && continue
    grep -qE "no matching package named|failed to download|attempting to make an HTTP request" <<<"$out" || continue
    # Online only for lockfiles whose every source is crates.io or a configured family source
    # (PR_GATE_LOCK_SOURCES, passed in as $3 already escaped): a PR must not point the runner at an
    # arbitrary host through its lock. Each prefix is matched to its path, so a loopback forge listed
    # as git+http://127.0.0.1:<port>/git/<owner>/ admits nothing else on loopback: another port or path
    # is some other local service. Each git source is pinned to a commit. Checking the lock suffices under --locked: every
    # source a manifest brings in ([patch], git or path dependencies) must already be in it, and a named
    # [registries] entry needs Cargo config, which the neutral directory below does not read.
    if grep -E "^source = " "$dir/Cargo.lock" | grep -vqE "^source = \"($3)"; then
      printf "skipped %s: a lock source outside crates.io and the family forge\n" "$(basename "$repo_dir")/$lock"
      continue
    fi
    # From an empty directory with --manifest-path: Cargo reads .cargo/config.toml from the working
    # directory upward, so the PR'"'"'s own config (source replacement, registries, proxies) is not read.
    if (cd "$neutral" && timeout 600 cargo fetch --locked --manifest-path "$repo_dir${lock%.lock}.toml") >/dev/null 2>&1; then
      printf "fetched %s\n" "$(basename "$repo_dir")/$lock"
    else
      printf "could not fetch %s\n" "$(basename "$repo_dir")/$lock"
    fi
  done < <(git -C "$repo_dir" ls-files -z -- "${@:4}" ":!:*vendor/*" ":!:*fixtures/*" 2>/dev/null)
done'
"${enter[@]}" env -i -C "$worker_root" HOME="$HOME" USER="$(id -un)" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
  PATH="$TOOLS:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" GIT_LFS_SKIP_SMUDGE=1 \
  ionice -c 3 timeout 30m bash -c "$prefetch" pr-gate-prefetch "$worker_root" "$repo" "$LOCK_SOURCES_ERE" \
  6>&- 7>&- 9>&- >"$gate_attempt_dir/prefetch.log" 2>&1 \
  || say "locked-crate prefetch for $owner/$repo ended $?; the recipe reports any real gap"
if [[ -s "$gate_attempt_dir/prefetch.log" ]]; then
  say "$owner/$repo prefetch: $(grep -c '^fetched ' "$gate_attempt_dir/prefetch.log") lockfile(s) healed, $(grep -c '^could not fetch ' "$gate_attempt_dir/prefetch.log") not (see prefetch.log)"
fi
cache_env=()
[[ -z "$SCCACHE" ]] || cache_env=(RUSTC_WRAPPER="$SCCACHE" CARGO_INCREMENTAL=0 "${sccache_env[@]}")
root_env=()
for var in $WORKER_ROOT_VARS; do root_env+=("$var=$worker_root"); done
(
  cd "$run/$repo"
  exec setsid "${enter[@]}" env -i -C "$worker_root/$repo" HOME="$HOME" USER="$(id -un)" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    PATH="$TOOLS:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
    GIT_LFS_SKIP_SMUDGE=1 "${root_env[@]}" \
    JERYU_PLAYWRIGHT_WEB_PORT="$PLAYWRIGHT_WEB_PORT" \
    "${cache_env[@]}" ionice -c 3 \
    timeout --kill-after=30s 3h bash -c 'exec 6>&- 7>&- 9>&-; exec "$@"' pr-gate-worker "${recipe[@]}"
) >"$log" 2>&1 &
gate_worker=$!
gate_update --argjson worker "$gate_worker" '.worker_pid=$worker'
worker_exit=0
wait "$gate_worker" || worker_exit=$?
gate_worker=""
state=success
((worker_exit == 0)) || state=failure
((worker_exit != 124 && worker_exit != 137)) || state=timed_out
after_inputs="$gate_attempt_dir/after-inputs.json"
if ! PATH="$TOOLS:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" gate_inputs "$after_inputs" \
  || ! jq -e --slurpfile after "$after_inputs" '.inputs == $after[0]' "$gate_receipt" >/dev/null; then
  state=inputs_changed
fi
gate_finish "$state" "$worker_exit" "$log"
gate_publish || die "terminal $state saved; publication recovery required in $gate_receipt"
seconds=$(( $(date +%s) - started_s ))
jq -nc --arg repo "$owner/$repo" --argjson pr "$number" --arg sha "$sha" --arg recipe "$recipe_name" \
  --arg conclusion "$state" --argjson exit_code "$worker_exit" --argjson seconds "$seconds" --arg at "$(date -u +%FT%TZ)" \
  '{repo:$repo,pr:$pr,sha:$sha,recipe:$recipe,conclusion:$conclusion,exit_code:$exit_code,seconds:$seconds,finishedAt:$at}' \
  | gate_atomic "$LAST_GATE"
heartbeat
say "recorded $owner/$repo $(gate_required_context "$owner" "$repo")=$state; exit $worker_exit; evidence $gate_receipt"
# Attempt evidence is retained with its log, including active and unpublished results.
# Age does not discharge a recovery obligation. Preservation-aware retention must be
# qualified separately before any journal or legacy log is removed.
# A recorded red result is the runner doing its job, not a fault: exit 0 so systemd does
# not show a healthy slot as failed. Runner faults still die non-zero.
exit 0
done
heartbeat
say "no admitted head needs a new execution"
