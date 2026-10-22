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
#   3. refresh the local mirrors of that family's canonical mains;
#   4. decide reuse from the head's input identity, derived from those mirrors and from this host's
#      tools without preparing anything, and leave an unchanged head alone;
#   5. otherwise build a clean tree: every family repo at origin/main from the mirrors,
#      the PR's repo at exactly its head, the configured native vendor tree linked;
#   6. post `pending`, run `just required` there with the governed security
#      tools and the system npm first on PATH, then post success or failure
#      with the log's SHA-256 in the description;
#   7. retain terminal receipts and logs for verified reuse or publication recovery.
# At most one gate per tick. A PR whose head moves gets gated again because the
# status is keyed by commit.
#
# It never approves, merges, tags or waives anything. The token is the gate identity
# (GATE_RUNNER_IDENTITY), which must not be the author of the PRs it proves.
#
# Contributions: a PR the importer marked with PR_GATE_CONTRIBUTED_LABEL carries code nobody of the
# family wrote, so it gets neither this host's credentials nor an automatic run. Nothing of it is
# executed -- no recipe, no prefetch, no cache daemon -- until a maintainer named in
# PR_GATE_OK_TO_TEST_MAINTAINERS has allowed exactly its current head (PR_GATE_OK_TO_TEST_LABEL, read
# as GET /api/v1/gate-allowances?state=active). A push moves the head, which the allowance no longer
# names, so the allowance is spent and the next head needs a new one. When it is allowed, the recipe
# runs through PR_GATE_SANDBOX_COMMAND -- the site's ephemeral, network-restricted VM or container --
# with no forge token, no gate identity, no host home, no governed tools and no shared writable
# cache, and its result is posted as the usual <repo>/required status. An internal PR keeps the path
# above unchanged. A contribution that changes what the gate itself evaluates with (ops/ci/,
# .jeryu/ci.toml, Justfile, workflows; PR_GATE_GATE_INPUT_PATHS) is recorded in its receipt and named
# on its check run, so it is reviewed for that as well as gated.
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
# Usage: pr-gate-runner.sh [--repo [OWNER/]R --pr N] [--main-health] [--list]
#   --repo/--pr  gate this PR now, even if it already has a runner status
#   --main-health  gate protected main and post <repo>/main-health
#   --list       print what the next tick would gate and exit
#   --preflight  (alone) read-only release check: stale slot index locks, pinned-tool drift, each
#                family main's latest <repo>/required; exit 1 on a finding (pr-gate-preflight.sh)
# ---------------------------------------------------------------------------
set -euo pipefail
GATE_RUNNER_SCRIPT="$(realpath -- "${BASH_SOURCE[0]}")"
# Preflight takes no slot lock and posts nothing, so it is handed off before any runner state is touched.
if [[ "${1:-}" == --preflight ]]; then
  (($# == 1)) || { printf -- '--preflight takes no other argument\n' >&2; exit 2; }
  exec bash "$(dirname -- "$GATE_RUNNER_SCRIPT")/pr-gate-preflight.sh"
fi
# shellcheck source=ops/pr-gate/bin/pr-gate-config.sh
source "$(dirname -- "$GATE_RUNNER_SCRIPT")/pr-gate-config.sh"
pr_gate_load_config
# shellcheck source=ops/pr-gate/bin/pr-gate-state.sh
source "$(dirname -- "$GATE_RUNNER_SCRIPT")/pr-gate-state.sh"
# Hash the code that is running now, and the site configuration it read; gate inputs use this, not
# the files on disk later (see gate_inputs). Each script is named by its file name, not where this host
# installed it, and the configuration by the settings that can change a verdict
# (gate_site_config_digest), so the same runner configured alike hashes the same on every host.
# Each step is checked on its own: one assignment of several substitutions would check only the last.
gate_self_part() { gate_tool_line "$@" || { printf 'pr-gate-runner: cannot hash %s\n' "$2" >&2; exit 2; }; }
GATE_SELF_SHA256="$(gate_self_part pr-gate-config.sh "$(dirname -- "$GATE_RUNNER_SCRIPT")/pr-gate-config.sh")"
GATE_SELF_SHA256+=$'\n'"$(gate_self_part pr-gate-state.sh "$(dirname -- "$GATE_RUNNER_SCRIPT")/pr-gate-state.sh")"
GATE_SELF_SHA256+=$'\n'"$(gate_self_part "$(basename -- "$GATE_RUNNER_SCRIPT")" "$GATE_RUNNER_SCRIPT")"
GATE_SELF_SHA256+=$'\n'"$(gate_self_part pr-gate-backoff.sh "$(dirname -- "$GATE_RUNNER_SCRIPT")/pr-gate-backoff.sh")"
GATE_SITE_CONFIG_SHA256="$(gate_site_config_digest "$PR_GATE_CONFIG_FILE")"
GATE_SELF_SHA256+=$'\n'"$GATE_SITE_CONFIG_SHA256  site-config"

not_configured() { printf 'pr-gate-runner: %s is not configured (set it in %s)\n' "$1" "$PR_GATE_CONFIG_FILE" >&2; exit 2; }
BASE="${JERYU_BASE:-${PR_GATE_FORGE_URL:-}}"
BASE="${BASE%/}"
[[ -n "$BASE" ]] || not_configured PR_GATE_FORGE_URL
TOKEN_FILE="$(pr_gate_path "${JERYU_TOKEN_FILE:-}")"
[[ -n "$TOKEN_FILE" ]] || not_configured JERYU_TOKEN_FILE
HOME_DIR="${GATE_RUNNER_HOME:-$HOME/gate-runner}"
# shellcheck source=ops/pr-gate/bin/pr-gate-backoff.sh
source "$(dirname -- "$GATE_RUNNER_SCRIPT")/pr-gate-backoff.sh"
# shellcheck source=ops/pr-gate/bin/pr-gate-progress.sh
source "$(dirname -- "$GATE_RUNNER_SCRIPT")/pr-gate-progress.sh"
REPOS="${GATE_RUNNER_REPOS:-auto}"
OWNERS="${GATE_RUNNER_OWNERS:-}"
[[ "$REPOS" != auto || -n "${OWNERS// }" ]] || not_configured "GATE_RUNNER_OWNERS (or GATE_RUNNER_REPOS)"
# The owner whose mirrors and tree keep the unsuffixed paths (mirror/, tree), and whom a bare repo
# name means. Empty: every owner is suffixed, and a bare name is refused.
PRIMARY_OWNER="${PR_GATE_PRIMARY_OWNER:-}"
SLOT="${GATE_RUNNER_SLOT:-0}"
[[ "$SLOT" =~ ^[0-9]+$ ]] || { printf 'GATE_RUNNER_SLOT must be a number, not %s\n' "$SLOT" >&2; exit 2; }
FAMILY="${GATE_RUNNER_FAMILY:-}"   # space-separated sibling repos to mirror; default: every repo of the PR's owner under its checkout root
DEPENDENCIES="${PR_GATE_DEPENDENCIES:-}"
pr_gate_dependencies_valid "$DEPENDENCIES" || {
  printf 'PR_GATE_DEPENDENCIES must map unique owner/repo keys to sibling names separated by commas (or -)\n' >&2
  exit 2
}
TOOLS="${GATE_RUNNER_TOOLS:-$HOME_DIR/governed-tools/bin}"
# The one PATH a recipe (and its locked-crate prefetch) runs with. gate_inputs binds every directory on
# it (gate_host_environment), so a result names everything the recipe could have executed.
RECIPE_PATH="$TOOLS:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin"
# A native vendor tree (prebuilt third-party sources) linked at <repo>/target/native-vendor for the
# repositories in PR_GATE_NATIVE_VENDOR_REPOS, and hashed into the inputs of those in
# PR_GATE_NATIVE_VENDOR_INPUT_REPOS. Unset: no repository gets one.
VENDOR="$(pr_gate_path "${GATE_RUNNER_NATIVE_VENDOR:-}")"
VENDOR_REPOS="${PR_GATE_NATIVE_VENDOR_REPOS:-}"
VENDOR_INPUT_REPOS="${PR_GATE_NATIVE_VENDOR_INPUT_REPOS:-}"
RUNTIME_TOOLS="${GATE_RUNNER_RUNTIME_TOOLS:-$HOME_DIR/runtime-tools}"
# The shared ordinary-build cache store (see gate_golden_seed). Same filesystem as the slot trees.
BUILD_CACHE_STORE="${GATE_RUNNER_BUILD_CACHE_STORE:-$HOME_DIR/build-cache}"
# Owners whose family tree gets the runtime tools at <tree>/target/runtime-tools.
RUNTIME_TOOLS_OWNERS="${PR_GATE_RUNTIME_TOOLS_OWNERS:-}"
IDENTITY="${GATE_RUNNER_IDENTITY:-}"
[[ -n "$IDENTITY" ]] || not_configured GATE_RUNNER_IDENTITY
# Contributions (see the head of this file). The importer's mark, the maintainer's allowance, who may
# give it, and the sandbox every allowed contribution runs in.
CONTRIBUTED_LABEL="${PR_GATE_CONTRIBUTED_LABEL:-origin:contributed}"
OK_TO_TEST_LABEL="${PR_GATE_OK_TO_TEST_LABEL:-ok-to-test}"
OK_TO_TEST_MAINTAINERS="${PR_GATE_OK_TO_TEST_MAINTAINERS:-}"
SANDBOX_COMMAND="${PR_GATE_SANDBOX_COMMAND:-}"
# The sandbox command's own PATH. It is the host path of the container or VM tool, never the gate's
# governed tools: those live in the gate user's home, which no contribution may read.
SANDBOX_PATH="${PR_GATE_SANDBOX_PATH:-/usr/local/bin:/usr/bin:/bin}"
# Paths (globs, against the path as git reports it) whose change alters what the gate evaluates with.
GATE_INPUT_PATHS="${PR_GATE_GATE_INPUT_PATHS:-ops/ci/* ops/ci-kit/* ops/pr-gate/* .jeryu/ci.toml Justfile justfile .github/workflows/* .forgejo/workflows/* .gitea/workflows/*}"
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

# git answers the forge as the runner, from the runner's own token file, never as whoever the host's
# global git config names (a personal credential helper stopped answering for the forge and every
# private mirror failed). The first entry clears inherited helpers for the forge's git URLs; the
# second reads the token file when git asks, so the token is in no argv and no config file. These
# variables outrank the global and system config, and the recipe and its prefetch get them too.
# shellcheck disable=SC2016  # expanded by git's helper shell, not here
GIT_HELPER='!f() { [ "$3" = get ] || exit 0; printf "username=%s\npassword=%s\n" "$1" "$(cat "$2")"; }; f'
export GIT_CONFIG_COUNT=2 GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_KEY_0="credential.$BASE/git/.helper" GIT_CONFIG_VALUE_0=""
export GIT_CONFIG_KEY_1="credential.$BASE/git/.helper"
GIT_CONFIG_VALUE_1="$GIT_HELPER '$IDENTITY' '$TOKEN_FILE'"
export GIT_CONFIG_VALUE_1
git_env=(GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=2
  GIT_CONFIG_KEY_0="$GIT_CONFIG_KEY_0" GIT_CONFIG_VALUE_0=""
  GIT_CONFIG_KEY_1="$GIT_CONFIG_KEY_1" GIT_CONFIG_VALUE_1="$GIT_CONFIG_VALUE_1")

only_repo=""; only_pr=""; list=0; main_health=0
while (($#)); do case "$1" in
  --repo) only_repo="${2:?--repo needs a value}"; shift 2;;
  --pr) only_pr="${2:?--pr needs a number}"; shift 2;;
  --main-health) main_health=1; shift;;
  --list) list=1; shift;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2;;
esac; done
if ((main_health)); then
  [[ -z "$only_pr" ]] || { printf -- '--main-health gates repository main, not a PR\n' >&2; exit 2; }
  export GATE_CONTEXT_KIND=main-health
  release_guard="$(pr_gate_path "${GATE_RUNNER_RELEASE_GUARD_FILE:-}")"
  if [[ -n "$release_guard" && -e "$release_guard" ]]; then
    printf '[gate-runner %s slot %s] release guard is present; skipping main-health\n' "$(date -u +%FT%TZ)" "$SLOT"
    exit 0
  fi
fi

say() { printf '[gate-runner %s slot %s] %s\n' "$(date -u +%FT%TZ)" "$SLOT" "$*"; }
die() { say "FAIL: $*"; exit 1; }
[[ -r "$TOKEN_FILE" ]] || die "token file $TOKEN_FILE is not readable"
for tool in curl jq git just flock sha256sum; do command -v "$tool" >/dev/null || die "$tool is required"; done

mkdir -p "$HOOKS"
if [[ ! -x "$HOOKS/pre-push" ]]; then
  printf '#!/bin/sh\nprintf "pr-gate-runner: a gate never pushes\\n" >&2\nexit 1\n' >"$HOOKS/pre-push"
  chmod 0755 "$HOOKS/pre-push"
fi
mkdir -p "$HOME_DIR/mirror" "$HOME_DIR/runs" "$HOME_DIR/logs" "$HOME_DIR/claims" "$HOME_DIR/cache" "$HOME_DIR/targets" "$HOME_DIR/regate"
# Slot 0 keeps the original lock name, so an older single-slot install and slot 0 exclude each other.
lock_name=".lock"; ((SLOT == 0)) || lock_name=".lock-slot$SLOT"
exec 9>"$HOME_DIR/$lock_name"
flock -n 9 || { say "a gate is already running; nothing to do"; exit 0; }
# The lock lives on fd 9, and anything the gate starts inherits it unless told otherwise. A build
# daemon (sccache) spawned by `just required` detached with fd 9 open and held the lock after the
# gate had finished, so every later tick said "already running" and gated nothing. The recipe runs
# with fd 9 closed (see step 6).

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
#
# A 429 from any call starts the shared forge back-off (pr-gate-backoff.sh): until it passes, reads
# answer 429 locally without a request, so every slot stands back together instead of retrying each
# tick. Writes still go out, because a gate's verdict must not be lost to a read-side limit.
# GATE_API_PASSIVE (the progress watcher's posts) never clears a back-off: a write going through says
# nothing about the reads the forge limited.
api() { # method path [json]
  local hdr out args=(--silent --show-error --max-time 60 -X "$1"
    --config "$AUTH_CONFIG" -H 'Accept: application/json')
  [[ -z "${3:-}" ]] || args+=(-H 'Content-Type: application/json' --data "$3")
  if [[ "$1" == GET ]] && (($(backoff_remaining) > 0)); then code=429 body=""; return 0; fi
  hdr="$(mktemp)"
  out="$(curl "${args[@]}" --dump-header "$hdr" -w '\n%{http_code}' "$BASE$2")" || out=$'\n000'
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  if [[ "$code" == 429 ]]; then backoff_note_429 "$hdr"; elif [[ "$code" =~ ^2 && -z "${GATE_API_PASSIVE:-}" ]]; then backoff_clear; fi
  rm -f -- "$hdr"
}

# The link (target_url) is a convenience and never decides a gate: a forge that refuses it (422) gets
# the same status again without it, as the heartbeat retries without fields an older forge refuses.
#
# A 5xx (or no answer at all, 000) is the forge failing, not a verdict on the gate. The post is tried
# up to PR_GATE_STATUS_ATTEMPTS times (default 4, at most 10), PR_GATE_STATUS_RETRY_SLEEP seconds apart
# (default 5, at most 60). If the forge is still down, one best-effort `error` status says so on the
# PR before the runner gives up; it names no inputs, so the next tick gates the head again instead of
# reusing or holding it. A refusal that is not a 5xx (4xx) is a fault of this runner and dies at once.
STATUS_ATTEMPTS="${PR_GATE_STATUS_ATTEMPTS:-4}"
[[ "$STATUS_ATTEMPTS" =~ ^[0-9]+$ ]] && ((STATUS_ATTEMPTS >= 1 && STATUS_ATTEMPTS <= 10)) || STATUS_ATTEMPTS=4
STATUS_RETRY_SLEEP="${PR_GATE_STATUS_RETRY_SLEEP:-5}"
[[ "$STATUS_RETRY_SLEEP" =~ ^[0-9]+$ ]] && ((STATUS_RETRY_SLEEP <= 60)) || STATUS_RETRY_SLEEP=5
post_status() { # owner repo sha state description [target_url]
  local url=${6:-} attempt=1 failed_code failed_body
  while :; do
    api POST "/repos/$1/$2/statuses/$3" "$(jq -n --arg s "$4" --arg c "$(gate_status_context "$1" "$2")" \
      --arg d "$5" --arg u "$url" '{state: $s, context: $c, description: $d} + (if $u == "" then {} else {target_url: $u} end)')"
    if [[ "$code" == 422 && -n "$url" ]]; then
      say "status link refused (422); posting $1/$2 $4 without it"
      url=""
      continue
    fi
    if [[ "$code" =~ ^(5[0-9][0-9]|000)$ ]] && ((attempt < STATUS_ATTEMPTS)); then
      say "forge answered $code posting $1/$2 $4 on $3; retry $attempt of $((STATUS_ATTEMPTS - 1)) in ${STATUS_RETRY_SLEEP}s"
      attempt=$((attempt + 1))
      sleep "$STATUS_RETRY_SLEEP"
      continue
    fi
    break
  done
  [[ "$code" == 201 ]] && return 0
  failed_code=$code failed_body=$body
  if [[ "$code" =~ ^(5[0-9][0-9]|000)$ && "$4" != error ]]; then
    api POST "/repos/$1/$2/statuses/$3" "$(jq -n --arg c "$(gate_status_context "$1" "$2")" \
      --arg d "$MARKER: the forge answered $failed_code posting $4; the gate retries on the next tick" \
      '{state: "error", context: $c, description: $d}')"
  fi
  die "posting $1/$2 $(gate_status_context "$1" "$2")=$4 on $3 answered $failed_code: $failed_body"
}

main_health_is_current_green() { # status-snapshot
  jq -e --arg context "$(gate_main_health_context "$owner" "$repo")" --arg marker "$MARKER " '
    [.statuses[]? | select(.context == $context)] | sort_by(.updated_at // .created_at) | last
    | . != null and .state == "success" and ((.description // "") | startswith($marker))' "$1" >/dev/null
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
  if [[ "$code" == 422 ]]; then
    say "heartbeat shape refused (422); retrying with the oldest contract"
    api POST "/api/v1/runners/heartbeat" "$(gate_heartbeat_minimal "$payload")"
  fi
  if ! jq -e '.accepted == true' <<<"$body" >/dev/null 2>&1 && jq -e . <<<"$body" >/dev/null 2>&1; then
    say "heartbeat refused ($code): $(jq -c '.message // .' <<<"$body")"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The head this slot was woken for. pr-gate-wake.sh starts an idle slot the moment the forge says a
# head became gateable, and leaves the head it started that slot for in cache/wake-dispatch as
# "<owner/repo> <number|-> <sha|-> <source> <when|->". One line is taken per tick. A main-health pass
# reads cache/wake-main-dispatch instead, where a pushed default branch is a line naming the
# repository only ("<owner/repo> - - push <when>"): what moved its main is not a pull request, and
# whatever its main is by the time the pass runs is what that pass gates.
#
# It decides nothing: this tick still lists, chooses, claims and gates heads by the rules below. It
# only puts that head first of the pull-request heads this pass found -- so a woken slot gates what
# it was woken for instead of whatever its own pass happens to reach first -- and dates the queue
# wait that attempt records. A line nobody takes, or one for a head this tick refuses, costs the
# latency it was meant to save and nothing else.
#
# A line older than DISPATCH_TTL is dropped unread: the slot it was meant for never ran, and the
# timers behind it have long since covered that head.
# ---------------------------------------------------------------------------
DISPATCH="$HOME_DIR/cache/wake-dispatch"
# A main-health pass reads its own file: a push to a default branch names a repository and no pull
# request, and the two must not take each other's lines.
((main_health == 0)) || DISPATCH="$HOME_DIR/cache/wake-main-dispatch"
DISPATCH_TTL="${GATE_RUNNER_DISPATCH_TTL:-600}"
[[ "$DISPATCH_TTL" =~ ^[0-9]+$ ]] || die "GATE_RUNNER_DISPATCH_TTL must be a whole number of seconds"
ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})$'
hint_repo="" hint_pr="" hint_sha="" hint_source="" hint_at=""
# Take the oldest line that is still worth acting on, dropping what it steps over: every line read
# is removed, so two slots never take the same one and a malformed line is read once.
dispatch_take() {
  local line repo pr sha source at age rest
  [[ -s "$DISPATCH" ]] || return 0
  exec 5>"$DISPATCH.lock" || return 0
  flock -w 2 5 || { exec 5>&-; return 0; }
  while [[ -s "$DISPATCH" ]]; do
    line="$(head -n 1 "$DISPATCH")"
    rest="$(tail -n +2 "$DISPATCH")"
    printf '%s' "${rest:+$rest$'\n'}" >"$DISPATCH.tmp" && mv -f -- "$DISPATCH.tmp" "$DISPATCH"
    read -r repo pr sha source at <<<"$line"
    if ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$pr" =~ ^([0-9]+|-)$ \
        && "$sha" =~ ^([0-9a-f]{40}|-)$ && "$source" =~ ^[a-z-]{1,16}$ \
        && ( "$at" == - || "$at" =~ $ISO_RE ) ]]; then
      say "ignoring a malformed wake-up line: $line"
      continue
    fi
    if [[ "$at" != - ]]; then
      age=$(( $(date +%s) - $(date -d "$at" +%s 2>/dev/null || printf 0) ))
      ((age <= DISPATCH_TTL)) || { say "dropping a stale wake-up for $repo (${age}s old)"; continue; }
    fi
    hint_repo="$repo" hint_pr="$pr" hint_sha="$sha" hint_source="$source" hint_at="$at"
    say "woken for $repo$([[ "$pr" == - ]] || printf '#%s' "$pr") ($source)"
    break
  done
  exec 5>&-
}

# Whether the wake-up names this head. A push names a ref and a sha but no pull request; a queue
# commit and a re-gate name both.
dispatch_names() { # owner repo number sha
  [[ -n "$hint_repo" && "$hint_repo" == "$1/$2" ]] || return 1
  [[ "$hint_pr" == - || "$hint_pr" == "$3" ]] || return 1
  [[ "$hint_sha" == - || "$hint_sha" == "$4" ]] || return 1
}

# When a head became gateable, as the pull request itself dates it: it was opened, or it was changed
# -- a push moves the head, and so does a comment, but an unrelated change can only make a measured
# wait shorter, never invent one. The wake-up line dates it exactly when the forge told it when.
pr_ready_at() { # pr-json -> "<iso8601>|<source>", else "-"
  local opened moved
  opened="$(jq -r '.created_at // ""' <<<"$1")"
  moved="$(jq -r '.updated_at // ""' <<<"$1")"
  [[ "$opened" =~ $ISO_RE ]] || opened=""
  [[ "$moved" =~ $ISO_RE ]] || moved=""
  if [[ -n "$moved" && ( -z "$opened" || "$moved" > "$opened" ) ]]; then printf '%s|pr-updated' "$moved"
  elif [[ -n "$opened" ]]; then printf '%s|pr-opened' "$opened"
  else printf -- '-'; fi
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

# While the forge is rate limiting this identity (429), look at nothing:
# the shared back-off says when to come back, and the slot timer finds the work then.
if (( $(backoff_remaining) > 0 )); then
  say "the forge is rate limiting this identity; standing back for $(backoff_remaining)s"
  exit 0
fi

# Maintainer allowances for contributed heads, read once a tick: the forge records which head a
# maintainer applied the ok-to-test label to, as
#   {"allowances":[{"repo":"acme/widgets","number":7,"head_sha":"<40 hex>","label":"ok-to-test",
#                   "allowed_by":"dana","allowed_at":"2026-10-06T09:00:00Z"}]}
# at most one per PR. The runner decides for itself: it admits a contributed head only when an
# allowance names that exact head and a maintainer it was configured to trust gave it, so a forge
# that reports a stale or unknown-author allowance admits nothing. Every other answer leaves
# contributions ungated this tick, which is the fail-closed direction: a contribution not run is a
# PR waiting, a contribution run unallowed is this host running a stranger's code.
# Anything but 200 -- a forge without the route, one this identity cannot read it from -- leaves every
# contribution unallowed, and is named as the reason that head is not running rather than once a tick:
# a family with no contributions would otherwise log it forever.
declare -A allowed_sha=() allowed_by=() allowed_label=()
api GET "/api/v1/gate-allowances?state=active"
ALLOWANCES_CODE="$code"
if [[ "$code" == 200 ]]; then
  while IFS=$'\t' read -r arepo anumber asha alabel aby; do
    if ! [[ "$arepo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$anumber" =~ ^[0-9]+$ \
        && "$asha" =~ ^[0-9a-f]{40}$ && "$aby" =~ ^[A-Za-z0-9._-]{1,64}$ \
        && "$alabel" =~ ^[A-Za-z0-9._/-]{0,64}$ ]]; then
      say "ignoring a malformed ok-to-test allowance: $arepo#$anumber"; continue
    fi
    allowed_sha["$arepo#$anumber"]="$asha"
    allowed_by["$arepo#$anumber"]="$aby"
    allowed_label["$arepo#$anumber"]="$alabel"
  done < <(jq -r '.allowances[]? | [.repo, (.number|tostring), .head_sha, (.label // ""), (.allowed_by // "")] | @tsv' <<<"$body")
fi

# True when a PR carries a label, by exact name. The marking lives on jeryu's own pull request row
# (GET /api/v1/repos/:id/pulls, and .../pulls/:n): jeryu-deploy labels every row `origin:internal` or
# `origin:contributed`, set by the importer and never by the author. The GitHub-compatible v3 payload
# carries no labels, so it is not where this is read. A label is a string there, or a {name} object
# on a forge that spells labels the GitHub way; a row with no labels key has none.
gate_has_label() { # row-payload name
  [[ -n "$2" ]] || return 1
  jq -e --arg name "$2" 'any((.labels // .summary.labels // [])[]?;
    (if type == "string" then . else (.name // "") end) == $name)' <<<"$1" >/dev/null 2>&1
}

# Nothing, when this contributed head may be executed; else why it may not. The allowance must name
# the PR's current head (so a push spends it), carry the configured label if the forge reports one,
# and come from a configured maintainer.
gate_contribution_refusal() { # owner repo number head-sha
  local key="$1/$2#$3" granted by label
  if [[ -z "${OK_TO_TEST_MAINTAINERS// }" ]]; then
    printf 'PR_GATE_OK_TO_TEST_MAINTAINERS is not configured, so nobody can allow it'; return
  fi
  if [[ "$ALLOWANCES_CODE" != 200 ]]; then
    printf 'the forge answered %s for its ok-to-test allowances' "$ALLOWANCES_CODE"; return
  fi
  granted="${allowed_sha["$key"]:-}"
  if [[ -z "$granted" ]]; then printf 'no %s from a maintainer' "$OK_TO_TEST_LABEL"; return; fi
  if [[ "$granted" != "$4" ]]; then
    printf '%s names %s, not this head: a push spends it' "$OK_TO_TEST_LABEL" "${granted:0:12}"; return
  fi
  label="${allowed_label["$key"]:-}"
  if [[ -n "$label" && "$label" != "$OK_TO_TEST_LABEL" ]]; then
    printf 'allowed by %s, which is not %s' "$label" "$OK_TO_TEST_LABEL"; return
  fi
  by="${allowed_by["$key"]:-}"
  if ! pr_gate_listed "$OK_TO_TEST_MAINTAINERS" "$by"; then
    printf '%s came from %s, who is not a configured maintainer' "$OK_TO_TEST_LABEL" "${by:-nobody}"; return
  fi
  if [[ -z "$SANDBOX_COMMAND" ]]; then
    printf 'PR_GATE_SANDBOX_COMMAND is not configured, and a contribution runs nowhere else'; return
  fi
  return 0
}

# 1-2. choose the next head
candidates=()
[[ -z "$only_repo" ]] || only_repo="$(qualify "$only_repo")"
# A scheduled tick takes the head pr-gate-wake.sh woke this slot for, if it left one; a main-health
# pass takes the repository whose default branch moved, from its own file. --repo/--pr is somebody
# naming a head themselves, so it reads none; a tick that only lists leaves the line for the tick
# that will gate it.
[[ -n "$only_repo" || "$list" == 1 ]] || dispatch_take
for qualified in $REPOS; do
  qualified="$(qualify "$qualified")"
  [[ -z "$only_repo" || "$qualified" == "$only_repo" ]] || continue
  owner="${qualified%%/*}" repo="${qualified#*/}"
  if ((main_health)); then
    main_sha=""
    api GET "/api/v3/repos/$owner/$repo/branches/main"
    [[ "$code" != 200 ]] || main_sha="$(jq -r '.commit.sha // .sha // ""' <<<"$body")"
    if [[ ! "$main_sha" =~ ^[0-9a-f]{40}$ ]]; then
      say "cannot resolve $owner/$repo main ($code); skipping main-health"
      continue
    fi
    status_snapshot=$(mktemp "$HOME_DIR/cache/main-health-status-$SLOT.XXXXXXXX")
    api GET "/repos/$owner/$repo/commits/$main_sha/status"
    if [[ "$code" != 200 ]]; then
      rm -f -- "$status_snapshot"
      say "cannot read $owner/$repo main statuses ($code); skipping main-health"
      continue
    fi
    printf '%s\n' "$body" >"$status_snapshot"
    if [[ -z "$only_repo" ]] && main_health_is_current_green "$status_snapshot"; then
      rm -f -- "$status_snapshot"
      say "skip $owner/$repo main-health: $main_sha is unchanged since the last green run"
      continue
    fi
    rm -f -- "$status_snapshot"
    candidates+=("$owner $repo 0 $main_sha refs/heads/main 0 -")
    continue
  fi
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
    ready="$(pr_ready_at "$body")"
    contributed=0
    if gate_has_label "$(jq -c --argjson n "$number" 'first(.items[]? | select(.number == $n)) // {}' <<<"$rows")" \
        "$CONTRIBUTED_LABEL"; then
      contributed=1
      refusal="$(gate_contribution_refusal "$owner" "$repo" "$number" "$sha")"
      if [[ -n "$refusal" ]]; then
        say "not running $owner/$repo#$number (contributed): $refusal"
        continue
      fi
    fi
    candidates+=("$owner $repo $number $sha - $contributed $ready")
  done < <(jq -r '.items[]? | [.number, .head_sha] | @tsv' <<<"$rows" | sort -n)
done
# Merge queue (jeryu-deploy docs/merge-queue.md). The forge replays an approved PR onto its base tip as
# refs/queue/<base>/<n> and lands that exact commit by compare-and-swap once its required context is
# green, so a PR that fell behind main needs nobody to rebase it. The runner gates queue_sha exactly as
# it gates a PR head -- same recipe, tree, context and identity -- fetched through queue_ref. Entries go
# first: each is one gate from landing. A candidate's fifth field is its queue ref, "-" for a PR head.
queued=()
# Every entry this tick saw, admitted or refused, by queue sha: gate_queue_arrived looks only past it.
declare -A queue_seen=()
gated=" $(for q in $REPOS; do qualify "$q"; printf ' '; done)"
if [[ -z "$only_pr" && "$main_health" == 0 ]]; then
  api GET "/api/v1/merge-queue?state=building"
  if [[ "$code" == 200 ]]; then
    queue_rows="$body"
    while IFS=$'\t' read -r qrepo number sha qref; do
      queue_seen["$sha"]=1
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
      queued_ready="$(pr_ready_at "$body")"
      # A queue commit is the forge's replay of the PR's head onto its base, so the maintainer's
      # allowance for that head is what admits it; the sandbox gates the replay exactly as the head.
      # The origin marking is on jeryu's own row, read here; one that cannot be read is skipped.
      queued_head="$(jq -r '.head.sha // ""' <<<"$body")"
      api GET "/api/v1/repos/$owner%2F$repo/pulls/$number"
      [[ "$code" == 200 ]] || { say "cannot read queued $qrepo#$number's origin ($code); skipping"; continue; }
      contributed=0
      if gate_has_label "$body" "$CONTRIBUTED_LABEL"; then
        contributed=1
        refusal="$(gate_contribution_refusal "$owner" "$repo" "$number" "$queued_head")"
        if [[ -n "$refusal" ]]; then
          say "not running queued $qrepo#$number (contributed): $refusal"; continue
        fi
      fi
      queued+=("$owner $repo $number $sha $qref $contributed $queued_ready")
    done < <(jq -r '.entries[]? | [.repo, (.number|tostring), .queue_sha, .queue_ref] | @tsv' <<<"$queue_rows")
  else
    say "merge queue answered $code; gating PR heads only this tick"
  fi
fi

# A queue entry that arrived after this tick listed the queue, for a gated repository, that no slot
# has claimed yet. Entries go first only at the start of a tick, and a tick can spend minutes deciding
# PR heads that end in reuse: on 2026-10-12 an entry waited 2m48s while one slot walked such a list,
# and was taken only when an unrelated gate ended elsewhere. Ending the tick hands the entry to the
# next one, which starts within the timer's pause and puts it first. Entries the tick already saw are
# never counted, so one this runner refuses (its own work, an unreadable origin) cannot end every tick.
gate_queue_arrived() {
  local qrepo qsha
  api GET "/api/v1/merge-queue?state=building"
  [[ "$code" == 200 ]] || return 1
  while IFS=$'\t' read -r qrepo qsha; do
    [[ "$qrepo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$qsha" =~ ^[0-9a-f]{40}$ ]] || continue
    [[ -z "${queue_seen["$qsha"]:-}" && "$gated" == *" $qrepo "* ]] || continue
    [[ -z "$only_repo" || "$qrepo" == "$only_repo" ]] || continue
    [[ -d "$HOME_DIR/attempts/${qrepo%%/*}-${qrepo#*/}-$qsha" ]] && continue
    say "merge-queue entry $qrepo at $qsha arrived during this tick; ending it so the next tick gates it first"
    return 0
  done < <(jq -r '.entries[]? | [.repo, .queue_sha] | @tsv' <<<"$body")
  return 1
}
# Re-gate requests from the forge (jeryu-deploy: POST /api/v1/repos/:id/pulls/:n/regate, read here as
# GET /api/v1/gate-regate?state=pending). A gate result is reused while its inputs are identical and
# a failure is held, which is right for a head that failed on its own sources and wrong for one that
# failed on something else: a dependency fetch that timed out, a gate host that lost its cache. A
# request names the head it was asked for, and honouring it gates exactly that head again although a
# result for it exists. One request is one re-gate: the requested_at this runner honoured is recorded
# under regate/<owner>-<repo>-<sha> when the attempt begins, and the forge keeps one request per PR,
# so a request is never replayed and asking again records a newer time. --repo/--pr already retries,
# so it reads nothing. A request never admits a head the rules above refused (the runner's own work,
# a closed PR, a moved head): it only decides whether an admitted head is gated again.
declare -A regate_at=()
if [[ -z "$only_pr" && "$main_health" == 0 ]]; then
  api GET "/api/v1/gate-regate?state=pending"
  if [[ "$code" == 200 ]]; then
    while IFS=$'\t' read -r rrepo rnumber rsha rat; do
      if ! [[ "$rrepo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$rnumber" =~ ^[0-9]+$ \
          && "$rsha" =~ ^[0-9a-f]{40}$ && "$rat" =~ ^[0-9A-Za-z:.+-]{1,64}$ ]]; then
        say "ignoring a malformed re-gate request: $rrepo#$rnumber"; continue
      fi
      regate_at["$rrepo#$rnumber $rsha"]="$rat"
    done < <(jq -r '.requests[]? | [.repo, (.number|tostring), .head_sha, .requested_at] | @tsv' <<<"$body")
  elif [[ "$code" != 404 ]]; then
    # 404 is a forge without the route; anything else is a forge this identity cannot read it from,
    # which would silently ignore every re-gate asked for, so say it.
    say "re-gate requests answered $code; gating this tick without them"
  fi
fi

# The requested_at of a re-gate this tick owes one head, or nothing: a request for that exact head
# whose time is not the one already recorded for it.
gate_regate_wanted() { # owner repo number sha
  local at="${regate_at["$1/$2#$3 $4"]:-}"
  [[ -n "$at" ]] || return 1
  [[ "$at" != "$(cat "$HOME_DIR/regate/$1-$2-$4" 2>/dev/null || true)" ]]
}

# Heads never gated go first after the queue. A sibling's main moving invalidates every open result in
# the family, and re-proving those in PR order put each new head behind all of them, one tree
# preparation at a time. Only the order changes; every head is still decided exactly as before.
# Those re-gates are automatic, and bounded by coalescing (see gate_regate_settling): while the family's
# mains moved within GATE_RUNNER_REGATE_SETTLE seconds (default 90), an already-gated head waits for the
# burst to end. --repo/--pr is never deferred.
fresh=() seen_before=()
for candidate in "${candidates[@]}"; do
  read -r owner repo number sha qref contributed ready <<<"$candidate"
  [[ "$owner" != . && "$owner" != .. && "$repo" != . && "$repo" != .. ]] || die "invalid repository path in dispatch"
  if [[ ! -d "$HOME_DIR/attempts/$owner-$repo-$sha" ]]; then fresh+=("$candidate"); continue; fi
  # Somebody asked for this head: it is as urgent as a new one, and coalescing a burst of merges is
  # not a reason to make them wait for it.
  if gate_regate_wanted "$owner" "$repo" "$number" "$sha"; then
    say "re-gate requested for $owner/$repo#$number at $sha"
    fresh+=("$candidate"); continue
  fi
  if [[ "$main_health" == 0 && -z "$only_pr" ]] && gate_regate_settling "$HOME_DIR/cache/mains/$owner/$repo" "$REGATE_SETTLE"; then
    say "deferring re-gate of $owner/$repo#$number: $owner mains moved within ${REGATE_SETTLE}s"; continue
  fi
  seen_before+=("$candidate")
done
# The head this slot was woken for goes first of the pull-request heads: that is what makes a woken
# slot gate the head it was woken for rather than whatever its own pass reached first. Merge-queue
# entries stay ahead of all of them, each being one gate from landing. Without a wake-up the order
# is exactly what it was.
woken=() rest=()
for candidate in "${fresh[@]}" "${seen_before[@]}"; do
  read -r owner repo number sha qref contributed ready <<<"$candidate"
  if dispatch_names "$owner" "$repo" "$number" "$sha"; then woken+=("$candidate"); else rest+=("$candidate"); fi
done
candidates=("${queued[@]}" "${woken[@]}" "${rest[@]}")

if ((${#candidates[@]} == 0)); then ((list)) || heartbeat; say "$([[ "$main_health" == 1 ]] && printf 'no main-health repo needs gating' || printf 'no PR head needs gating')"; exit 0; fi
if ((list)); then printf '%s\n' "${candidates[@]}"; exit 0; fi
# FD7 protects the shared repository target; FD6 protects the full-head journal.
# FD9 protects this slot's source tree. The timeout supervisor retains all three
# through parent death; the recipe closes them before it can start cache daemons.
# The slot's cache daemon is started by the worker itself, after it has closed all three.
#
# A head whose result was adopted from the forge (another host's, see gate_decision) is skipped while
# anything else needs this slot, and remembered. A tick that ends with nothing executed re-proves the
# first one with forge reuse off, so this host's own receipt replaces the adoption one head per idle tick.
forge_adopted=()
GATE_FORGE_REUSE=1
while :; do
for candidate in "${candidates[@]}"; do
read -r owner repo number sha qref contributed ready <<<"$candidate"
[[ "$owner" =~ ^[A-Za-z0-9._-]+$ && "$repo" =~ ^[A-Za-z0-9._-]+$ && "$sha" =~ ^[0-9a-f]{40}$ \
   && ( "$qref" == - || "$qref" == refs/heads/main || "$qref" =~ ^refs/queue/[A-Za-z0-9._/-]+$ ) \
   && "$contributed" =~ ^[01]$ && ( "$ready" == - || "$ready" =~ ^[^[:space:]]+\|[a-z-]+$ ) ]] \
  || die "invalid repository or head in dispatch"
if [[ "$qref" == - && -z "$only_pr" ]] && gate_queue_arrived; then
  heartbeat
  exit 0
fi
# A contribution is executed in the site's sandbox, and nowhere else. GATE_SANDBOX is read by
# gate_inputs and gate_begin, so what ran is part of the result's identity and of its receipt.
sandbox="$contributed"
GATE_SANDBOX="$sandbox"
if [[ -d "$HOME_DIR/claims/$owner-$repo-$sha" ]]; then
  say "recovery required: retained legacy claim for $owner/$repo@$sha; reconcile its worker before admission"
  continue
fi
# The repository lock keeps two slots out of one shared build directory. A repository that builds in
# its own slot tree (every one not in GATE_RUNNER_SHARED_TARGETS) has nothing to protect, and taking
# the lock anyway ran two PRs of one repository strictly one after the other.
shares_target=0
# A contribution never writes a cache anything else reads, so it shares no build directory and takes
# no repository lock for one.
for pattern in $( ((sandbox)) || printf '%s' "${GATE_RUNNER_SHARED_TARGETS:-}" ); do
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

# 3. the family's canonical mains
family="$FAMILY"
declared_dependencies=0
if dependencies=$(pr_gate_lookup "$DEPENDENCIES" "$owner/$repo"); then
  declared_dependencies=1
  family="${dependencies//,/ }"
  [[ "$family" != - ]] || family=""
elif [[ -z "$family" ]]; then
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
    if ((declared_dependencies)); then
      # Fail this head, not the tick: like a repository with no main of its own, every other
      # candidate is still gated. Dying here would repeat on every tick and starve the queue.
      post_status "$owner" "$repo" "$sha" failure "declared dependency $owner/$n has no canonical main ($MARKER)"
      say "declared dependency $owner/$n has no canonical main; $owner/$repo cannot be gated"
      flock -u 8; exec 6>&-; exec 7>&-
      continue 2
    fi
    # Drop the mirror as well. A repository whose main was deleted upstream would otherwise keep an
    # older main here, and step 5 would check the sibling out from it: a phantom main in the tree
    # while this line says the tree lacks it. With no mirror, step 5 skips the sibling.
    # Check the current owner's persistent tree below, after selecting its path.
    # An inherited or previous candidate's $run is not cleanup authority.
    rm -rf -- "$m"
    say "$owner/$n has no canonical main; the tree will lack it"
    flock -u 8; continue
  fi
  flock -u 8
done
exec 8>&-
# Different repositories may have different closures; they must not reset each other's settle clock.
mkdir -p "$HOME_DIR/cache/mains/$owner"
gate_record_mains "$HOME_DIR/cache/mains/$owner/$repo" "$mirrors" $family $repo || say "could not record $owner/$repo mains"

# 4. reuse an identical result before preparing a tree
# Most of what a tick examines is a head nobody has touched since it was gated, and the only way to
# find that out used to be a full preparation: mirror checkout, reset, clean, stamp and a tree-wide
# fingerprint of every sibling, ~6s a head. In a 24h sample on the gate host (2026-10-09/10) two
# slots spent ~35 slot-hours preparing ~40 unchanged heads some 310 times each, against ~8h of real
# gating, and a new head queued behind that sweep. gate_input_cheap derives the very same identity
# from the mirrors just fetched and from the tools and runner hashes computed now, so a sibling main
# that moved, a reinstalled governed tool or an upgraded runner is a changed input exactly as before
# and the tree is prepared after all; anything it cannot derive is a changed input too.
# Only `reuse` and `hold` end a head here: both run nothing and publish nothing, so no tree is
# needed for either. `republish` and `run` fall through, and the full preparation decides again.
# A retry of this head -- an explicit --repo/--pr, a re-gate the forge asked for -- is exactly what
# must re-run a held failure, so it never stops here.
retry_wanted=0
[[ -z "$only_repo" && -z "$only_pr" ]] || retry_wanted=1
! gate_regate_wanted "$owner" "$repo" "$number" "$sha" || retry_wanted=1
# A slot tree that needs recovery is not a tree whose result is reused: a sibling checkout left
# behind after its canonical main vanished is refused aloud by the preparation below, and reusing
# past it would silence that for as long as the head stayed open. Only the path of the tree is read
# here; the tree itself is still not prepared. (The owner's tree path is only chosen now, after its
# mirrors, so no inherited $run can be mistaken for it.)
run="$(tree_dir "$owner")"
for n in $family; do
  [[ "$n" != "$repo" && ! -d "$mirrors/$n.git" ]] || continue
  [[ -e "$run/$n" || -L "$run/$n" ]] || continue
  retry_wanted=1
done
if ((retry_wanted == 0)); then
  cheap_identity=$(mktemp "$HOME_DIR/cache/cheap-inputs-$SLOT.XXXXXXXX")
  cheap_statuses=$(mktemp "$HOME_DIR/cache/cheap-status-$SLOT.XXXXXXXX")
  cheap_action=""
  if PATH="$RECIPE_PATH" \
      gate_input_cheap "$cheap_identity" "$gate_key_dir/last-result.json"; then
    api GET "/repos/$owner/$repo/commits/$sha/status"
    if [[ "$code" == 200 ]]; then
      printf '%s\n' "$body" >"$cheap_statuses"
      gate_decision "$cheap_identity" 0 "$cheap_statuses"
      case "${gate_action:?}" in reuse|hold) cheap_action="$gate_action";; esac
    else
      say "cannot read the current status of $owner/$repo@$sha ($code); preparing its tree to decide"
    fi
  fi
  rm -f -- "$cheap_identity" "$cheap_statuses"
  if [[ -n "$cheap_action" ]]; then
    say "$cheap_action $owner/$repo@$sha: identical verified inputs, read without preparing a tree (a failure re-runs only with --repo <o>/<r> --pr <n>, or changed inputs)"
    exec 6>&-; exec 7>&-
    continue
  fi
fi
say "preparing $owner/$repo#$number at $sha${qref:+$([[ "$qref" == - ]] || printf ' (merge queue %s)' "$qref")}"

# 5. clean tree
# One persistent family tree, reset to exact commits for every gate. Build output is the only
# thing kept between gates: every repo is detached at its commit, hard-reset, and cleaned of all
# untracked and ignored files EXCEPT target/ and node_modules/. Sources are therefore exactly the
# commits under test; only compiled artifacts carry over, and cargo and pnpm verify those against
# the sources. A fresh clone per gate made every run a cold build -- one web repository took ~25
# minutes rebuilding a 16 GB target/ that the previous gate had already produced.
# One gate at a time holds the lock, so one tree is enough. A red gate's diagnostics stay in the
# tree until the next gate starts; its log is kept regardless. Its path was chosen in step 4.
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
  # Every slot's checkout of a repo builds into one shared target directory (step 5), and cargo
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
detached=$(gate_detach_strays "$run" "$HOME_DIR/detached/slot$SLOT" $family $repo) \
  || die "cannot remove undeclared checkouts from $owner/$repo's slot tree"
for n in $detached; do
  say "moved $owner/$n out of the slot tree: not in this gate's family"
done
mapfile -t evidence < <(gate_evidence_for "$owner")
if ((${#evidence[@]})); then
  while read -r line; do say "$line"; done < <(gate_mirror_evidence "$run" "$BASE" "${evidence[@]}")
fi
if [[ "$main_health" == 1 ]]; then
  git -C "$run/$repo" fetch --quiet "$BASE/git/$owner/$repo.git" '+refs/heads/main:refs/gate/main-health'
  if [[ "$(git -C "$run/$repo" rev-parse refs/gate/main-health)" != "$sha" ]]; then
    say "$owner/$repo main moved on from $sha; leaving it for the next tick"
    exec 6>&-; exec 7>&-
    continue
  fi
elif [[ "$qref" == - ]]; then
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
# Does this head change the gate it is judged by? The recipe below is the head's own, so a diff that
# touches the Justfile, ops/ci or the jankurai and policy files it reads rewrote the check that is
# about to report. It is recorded on the attempt and annotated on the check run (gate_publish); it
# changes no conclusion, and nothing here reruns the recipe from protected main. mirror/main is that
# protected main in this tree (sync_repo keeps it there).
if [[ "$main_health" == 1 ]]; then
  self_gate_paths=()
else
  mapfile -t self_gate_paths < <(gate_definition_paths "$run/$repo" mirror/main "$sha")
fi
self_gate_json='[]'
if ((${#self_gate_paths[@]} > 0)); then
  self_gate_json=$(printf '%s\n' "${self_gate_paths[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  say "$owner/$repo#$number changes its own gate: ${self_gate_paths[*]}"
fi
# What a contribution changes about the gate itself (see the head of this file). Read from the
# checkout against the merge base with protected main, so it is the PR's own change and not main's.
# Recorded on the attempt below and named on the check run beside the self-gate note above, never on
# the required status (that is the gate's own verdict); it never changes whether the gate runs.
gate_input_touched=()
if ((sandbox)); then
  while IFS= read -r changed; do
    [[ -n "$changed" ]] || continue
    if pr_gate_listed "$GATE_INPUT_PATHS" "$changed"; then gate_input_touched+=("$changed"); fi
  done < <(git -C "$run/$repo" diff --name-only mirror/main...HEAD 2>/dev/null)
  ((${#gate_input_touched[@]} == 0)) \
    || say "$owner/$repo#$number changes gate inputs (${gate_input_touched[*]}): extra review required"
fi
# Some family integrity tests need governed runtime fixtures (a pinned typesetter, say) at the family
# root's target/, the same shape the release host has. Without them the whole recipe fails on a
# missing tool and says nothing about the commit under test. PR_GATE_RUNTIME_TOOLS_OWNERS names them.
if ((sandbox)); then
  # The runtime fixtures live in the gate user's home, which the sandbox does not mount: a recipe
  # that needs them fails in the sandbox and says so, which is the honest answer for a contribution.
  rm -f -- "$run/target/runtime-tools"
elif pr_gate_listed "$RUNTIME_TOOLS_OWNERS" "$owner" && [[ -d "$RUNTIME_TOOLS" ]]; then
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
((sandbox == 0)) || SHARED_TARGETS=""   # a contribution builds only in its own tree
if ((sandbox)); then
  # The sandbox sees the whole slot tree, siblings' retained build caches included. Revoke every
  # cache this slot holds for the owner and remove the caches themselves before a contribution runs,
  # so no later trusted gate can reuse an output a contribution could have written.
  rm -rf -- "${HOME_DIR:?}/cache/build-target/$SLOT/$owner"
  for d in "$run"/*/target/build-cache; do [[ ! -e "$d" && ! -L "$d" ]] || rm -rf -- "$d"; done
fi
shared_target=""
for pattern in $SHARED_TARGETS; do
  # shellcheck disable=SC2053
  if [[ "$owner/$repo" == $pattern || "$repo" == $pattern ]]; then
    shared_target="$HOME_DIR/targets/$owner/$repo"; break
  fi
done
# Ordinary-build cache: one store per repository shared by every slot (gate_golden_* in
# pr-gate-state.sh). A slot never keeps a cache of its own between gates; it copies the store's
# current version in once the gate's cache key is known (below), and its copy is published or
# deleted when the gate ends. Per-slot authorizations from before the store are retired here.
build_cache=0
build_cache_store="$BUILD_CACHE_STORE/$owner/$repo"
rm -rf -- "${HOME_DIR:?}/cache/build-target/$SLOT"
if ((sandbox == 0)) && pr_gate_listed "${PR_GATE_BUILD_CACHE_REPOS:-}" "$owner/$repo"; then
  [[ -z "$shared_target" ]] || die "PR_GATE_BUILD_CACHE_REPOS cannot overlap GATE_RUNNER_SHARED_TARGETS"
  build_cache=1
fi
if [[ -z "$shared_target" ]]; then
  gate_prepare_target "$run/$repo/target" 0 || die "cannot prepare physical target for $owner/$repo"
  say "$owner/$repo has fresh outputs in its own tree"
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
if ((sandbox)); then
  rm -f -- "$run/$repo/target/native-vendor"   # a host path, and not the sandbox's to read
elif [[ -n "$VENDOR" && -d "$VENDOR" ]] && pr_gate_listed "$VENDOR_REPOS" "$repo" "$owner/$repo"; then
  mkdir -p "$run/$repo/target" && ln -sfn "$VENDOR" "$run/$repo/target/native-vendor"
fi

# 6. gate
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
PATH="$RECIPE_PATH" gate_inputs "$identity"
api GET "/repos/$owner/$repo/commits/$sha/status"
[[ "$code" == 200 ]] || die "cannot verify current status for $owner/$repo@$sha ($code)"
printf '%s\n' "$body" >"$status_snapshot"
retry=0; [[ -z "$only_pr" && "$main_health" == 0 ]] || retry=1
# A requested re-gate is a retry of this head: gate_decision must neither reuse its success nor hold
# its failure.
regate_now=""
if gate_regate_wanted "$owner" "$repo" "$number" "$sha"; then
  regate_now="${regate_at["$owner/$repo#$number $sha"]}"
  retry=1
fi
gate_decision "$identity" "$retry" "$status_snapshot"
case "${gate_action:?}" in
  reuse|hold)
    say "$gate_action $owner/$repo@$sha: identical verified inputs, from the ${gate_action_source:-local} result (a failure re-runs only with --repo <o>/<r> --pr <n>, or changed inputs)"
    [[ "${gate_action_source:-local}" != forge ]] || forge_adopted+=("$candidate")
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
build_cache_key=""
if ((build_cache)); then
  build_cache_key=$(gate_build_cache_key "$identity" "$repo" "$run/$repo") || die "cannot bind $owner/$repo build cache"
  mkdir -p "$run/$repo/target/build-cache"
  seed_started=$(date +%s)
  if seeded=$(gate_golden_seed "$build_cache_store" "$build_cache_key" "$run/$repo/target/build-cache"); then
    say "seeded $owner/$repo build cache from shared version $seeded in $(( $(date +%s) - seed_started ))s"
  else
    say "$owner/$repo builds cold: no shared build cache for this key"
  fi
fi
# A head moving during preparation must not run under the earlier admission. A queue commit is still
# admitted only while its entry is building at the same sha.
checks_url="" base_branch=""
if [[ "$main_health" == 1 ]]; then
  api GET "/api/v3/repos/$owner/$repo/branches/main"
  [[ "$code" == 200 ]] || die "cannot refresh main before admission ($code)"
  admitted=0
  [[ "$(jq -r '.commit.sha // .sha // ""' <<<"$body")" == "$sha" ]] && admitted=1
elif [[ "$qref" == - ]]; then
  api GET "/api/v3/repos/$owner/$repo/pulls/$number"
  [[ "$code" == 200 ]] || die "cannot refresh PR before admission ($code)"
  admitted=0
  [[ "$(jq -r '.head.sha' <<<"$body")" == "$sha" && "$(jq -r '.state' <<<"$body")" == open ]] && admitted=1
  # The checks page of exactly this pull request, from the forge's answer for it just now. A queue
  # commit and main-health link nothing: no PR checks page shows their sha.
  checks_url=$(gate_checks_url "$owner" "$repo" "$number" "$body")
  base_branch="$(jq -r '.base.ref // ""' <<<"$body")"
else
  api GET "/api/v1/merge-queue?state=building"
  [[ "$code" == 200 ]] || die "cannot refresh the merge queue before admission ($code)"
  admitted=0
  jq -e --arg r "$owner/$repo" --argjson n "$number" --arg s "$sha" \
    'any(.entries[]?; .repo == $r and (.number|tonumber) == $n and .queue_sha == $s)' <<<"$body" >/dev/null && admitted=1
  # refs/queue/<base>/<n>: the entry's own base branch.
  base_branch="${qref#refs/queue/}"; base_branch="${base_branch%/*}"
fi
if ((admitted == 0)); then
  say "head changed or PR closed before admission (or its queue entry moved): $owner/$repo#$number"
  rm -f -- "$identity" "$status_snapshot"
  exec 6>&-; exec 7>&-
  continue
fi
# The proof base. A recipe compares against a base ref that defaults to origin/main, which a release
# line does not descend from. When the site names that variable for this owner, the recipe gets
# origin/<the PR's base branch>, fetched into this tree; a base that cannot be had fails the gate here
# with that reason rather than inside the recipe. main-health and owners with no variable are unchanged.
proof_base_env=()
proof_base_var="$(gate_proof_base_var "$owner")" || die "PR_GATE_PROOF_BASE_VARS: $owner's entry is not a variable name"
base_err=""
# A forge that does not report the base leaves the recipe's own default, as it did before.
if [[ -n "$proof_base_var" && "$main_health" == 0 && -n "$base_branch" ]]; then
  if ! base_branch="$(gate_base_branch "$base_branch")" \
      || ! base_err="$(gate_fetch_base "$run/$repo" "$BASE/git/$owner/$repo.git" "$base_branch" 2>&1)"; then
    base_err="${base_err:-base branch of $owner/$repo#$number is not a usable branch name}"
    say "$owner/$repo#$number: $base_err"
    post_status "$owner" "$repo" "$sha" failure "no gate: proof base unavailable: ${base_err:0:120} ($MARKER)"
    rm -f -- "$identity" "$status_snapshot"
    exec 6>&-; exec 7>&-
    continue
  fi
  proof_base_env=("$proof_base_var=origin/$base_branch")
fi
gate_begin "$identity"
: "${gate_attempt_dir:?}"
# On the attempt, so recovery publishes the same annotation from the same evidence as this process would.
gate_update --argjson paths "$self_gate_json" '.gate_definition_paths=$paths' \
  || say "could not record the gate-defining paths of $owner/$repo@$sha"
# The queue wait: from the moment this head became gateable to the moment its gate started. It is
# what says whether a gate waited for a slot rather than took one, so it is recorded on the attempt
# and carried by the gate.log event (see pr-gate-heartbeat.sh). The wake-up that started this slot
# dates the head when the forge told it when; otherwise the pull request dates itself. Clocks that
# disagree are recorded as an unknown wait rather than a negative one, with both times kept.
ready_at="" ready_source=""
if dispatch_names "$owner" "$repo" "$number" "$sha" && [[ "$hint_at" != - ]]; then
  ready_at="$hint_at" ready_source="$hint_source"
elif [[ "$ready" != - ]]; then
  ready_at="${ready%%|*}" ready_source="${ready##*|}"
fi
if [[ -n "$ready_at" ]]; then
  queue_wait=null
  ready_s="$(date -d "$ready_at" +%s 2>/dev/null || true)"
  gate_start_s="$(date -d "$(jq -r '.started_at' "$gate_receipt")" +%s 2>/dev/null || true)"
  if [[ "$ready_s" =~ ^[0-9]+$ && "$gate_start_s" =~ ^[0-9]+$ ]] && ((gate_start_s >= ready_s)); then
    queue_wait=$((gate_start_s - ready_s))
  fi
  gate_update --arg at "$ready_at" --arg source "$ready_source" --argjson seconds "$queue_wait" \
    '.queue_wait={ready_at:$at,source:$source,seconds:$seconds}' \
    || say "could not record the queue wait of $owner/$repo@$sha"
  say "queue wait $([[ "$queue_wait" == null ]] && printf unknown || printf '%ss' "$queue_wait") ($ready_source $ready_at -> gate start)"
fi

if ((${#gate_input_touched[@]})); then
  gate_update --argjson paths "$(printf '%s\n' "${gate_input_touched[@]}" | jq -Rsc 'split("\n")[:-1]')" \
    '.gate_input_paths=$paths' || say "could not record the gate inputs $owner/$repo#$number changes"
fi
# The request is discharged by the attempt it started, not by the attempt's outcome: a gate that
# dies leaves recovery to finish, and reading the request as still owed would gate the same head on
# every tick until it moved.
[[ -z "$regate_now" ]] || printf '%s\n' "$regate_now" | gate_atomic "$HOME_DIR/regate/$owner-$repo-$sha" \
  || say "could not record the honoured re-gate of $owner/$repo@$sha"
# Re-verifying a head whose newest required status is this runner's own success does not post
# `pending` over it: merge readiness reads the newest status, so each re-verification made a passing PR
# unmergeable until it finished (jeryu-web#23: 12 passes in an hour, ~15s green windows). The success
# stays until this attempt's conclusion replaces it -- a failure is still published the moment it exists.
keep_green=0
gate_newest_is_own_success "$status_snapshot" && keep_green=1
rm -f -- "$identity" "$status_snapshot"
log="$gate_attempt_dir/build.log"
steps_tsv="$gate_attempt_dir/steps.tsv"
: >"$steps_tsv"
# What a step may be published as: protected main's gate sources (pr-gate-progress.sh). Local only.
step_sources="$gate_attempt_dir/step-sources"
gate_step_vocabulary "$run/$repo" mirror/main "$step_sources" || say "could not read $owner/$repo main's gate sources; steps publish unnamed"
if ((keep_green)); then
  say "re-verifying $owner/$repo@$sha without pending: its newest $(gate_status_context "$owner" "$repo") is this runner's success"
else
  post_status "$owner" "$repo" "$sha" pending "$(gate_execution_kind) $recipe_name running on $MARKER; attempt $(jq -r '.id' "$gate_receipt")" "$checks_url"
fi
# shellcheck disable=SC2016  # a jq program: $url is jq's
gate_update --arg url "$checks_url" '.phase="running" | .checks_url=$url'
started_at="$(date -u +%FT%TZ)" started_s="$(date +%s)"
heartbeat "$(jq -nc --arg repo "$owner/$repo" --argjson pr "$number" --arg sha "$sha" \
  --arg recipe "$recipe_name" --arg at "$started_at" --arg kind "$([[ "$main_health" == 1 ]] && printf main-health || printf pr)" \
  '{repo:$repo,pr:$pr,sha:$sha,recipe:$recipe,startedAt:$at,kind:$kind}')"
# Remove inherited credential variables. This operator path is still not a
# sealed worker: installed credential/UID isolation belongs to SplitOps promotion.
# A slot >0 binds its tree over slot 0's path in a private mount namespace (root only for the mount;
# setpriv drops back to this user before anything of the recipe runs). sudo keeps our real uid, so
# the process-group kill in gate cleanup still reaches it and it relays the signal to the recipe.
worker_root="$run" enter=()
if ((sandbox)); then
  # The sandbox is the isolation, and it brings its own view of the filesystem: no mount namespace of
  # ours, no shared compile cache, no prefetch into the shared registry.
  say "$owner/$repo#$number is a contribution: running it in the configured sandbox, without this host's credentials, home, tools or caches"
elif pr_gate_listed "$PHYSICAL_PATH_REPOS" "$owner/$repo"; then
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
((sandbox == 0)) || SCCACHE=""   # a contribution writes no cache this host or another gate reads
if [[ -n "$SCCACHE" ]]; then
  # A fresh server per gate, started in the same view of the sources the recipe gets: an older one
  # may hold another namespace. It must not inherit the head, target or slot lock.
  # shellcheck disable=SC2016  # expanded by the inner sh
  # The server runs the compiles, so it takes the recipe's idle I/O class (see the worker below).
  "${enter[@]}" env -i HOME="$HOME" PATH="$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" "${sccache_env[@]}" \
    ionice -c 3 sh -c '"$0" --stop-server; "$0" --start-server' "$SCCACHE" 6>&- 7>&- 9>&- >/dev/null 2>&1 \
    || { say "sccache did not start on port $SCCACHE_PORT; $owner/$repo builds uncached"; SCCACHE=""; }
elif ((SCCACHE_MISSING && sandbox == 0)); then
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
if ((sandbox)); then
  # The prefetch heals the host's shared Cargo registry, which is exactly a shared writable cache: a
  # contribution neither reads nor writes it. Its sandbox resolves dependencies on its own, within
  # whatever network the site allows it.
  say "$owner/$repo#$number skips the locked-crate prefetch: a contribution shares no registry"
else
  "${enter[@]}" env -i -C "$worker_root" HOME="$HOME" USER="$(id -un)" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    PATH="$RECIPE_PATH" GIT_LFS_SKIP_SMUDGE=1 "${git_env[@]}" \
    ionice -c 3 timeout 30m bash -c "$prefetch" pr-gate-prefetch "$worker_root" "$repo" "$LOCK_SOURCES_ERE" \
    6>&- 7>&- 9>&- >"$gate_attempt_dir/prefetch.log" 2>&1 \
    || say "locked-crate prefetch for $owner/$repo ended $?; the recipe reports any real gap"
fi
if [[ -s "$gate_attempt_dir/prefetch.log" ]]; then
  say "$owner/$repo prefetch: $(grep -c '^fetched ' "$gate_attempt_dir/prefetch.log") lockfile(s) healed, $(grep -c '^could not fetch ' "$gate_attempt_dir/prefetch.log") not (see prefetch.log)"
fi
cache_env=()
[[ -z "$SCCACHE" ]] || cache_env=(RUSTC_WRAPPER="$SCCACHE" CARGO_INCREMENTAL=0 "${sccache_env[@]}")
root_env=()
for var in $WORKER_ROOT_VARS; do root_env+=("$var=$worker_root"); done
root_env+=("${proof_base_env[@]}")
# Absolute: a recipe step that runs cargo from a subdirectory must still use the one cache this
# runner prepares and revokes, never create a nested target/ that survives between gates.
# Incremental state is never reused across gates, whether or not sccache is present to pin it.
((build_cache == 0)) || root_env+=(JERYU_CI_BUILD_CACHE_DIR="$worker_root/$repo/target/build-cache" CARGO_INCREMENTAL=0)
if ((sandbox)); then
  # The sandbox contract: <command> <tree-root> <repo> <recipe...>. The site's command puts the tree
  # root in an ephemeral, network-restricted VM or container at that same path, enters <repo> there
  # and runs the recipe. What the runner guarantees on this side is the environment: `env -i` with no
  # forge token and no path to one, no gate identity, no HOME or USER of the gate user, no governed
  # tools on PATH, no compile-cache or registry variables, and nothing of the site configuration
  # except that a sandbox is what this is. The tree itself is this gate's own slot tree, which the
  # next gate resets; nothing the contribution writes outlives it.
  read -r -a sandbox_cmd <<<"$SANDBOX_COMMAND"
  (
    cd "$run/$repo"
    exec setsid env -i PATH="$SANDBOX_PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      GIT_LFS_SKIP_SMUDGE=1 PR_GATE_SANDBOX=1 "${root_env[@]}" \
      JERYU_PLAYWRIGHT_WEB_PORT="$PLAYWRIGHT_WEB_PORT" \
      ionice -c 3 timeout --kill-after=30s 3h \
      bash -c 'exec 6>&- 7>&- 9>&-; exec "$@"' pr-gate-sandbox \
      "${sandbox_cmd[@]}" "$run" "$repo" "${recipe[@]}"
  ) >"$log" 2>&1 &
else
(
  cd "$run/$repo"
  exec setsid "${enter[@]}" env -i -C "$worker_root/$repo" HOME="$HOME" USER="$(id -un)" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    PATH="$RECIPE_PATH" \
    GIT_LFS_SKIP_SMUDGE=1 "${git_env[@]}" "${root_env[@]}" \
    JERYU_PLAYWRIGHT_WEB_PORT="$PLAYWRIGHT_WEB_PORT" \
    "${cache_env[@]}" ionice -c 3 \
    timeout --kill-after=30s 3h bash -c 'exec 6>&- 7>&- 9>&-; exec "$@"' pr-gate-worker "${recipe[@]}"
) >"$log" 2>&1 &
fi
gate_worker=$!
gate_update --argjson worker "$gate_worker" '.worker_pid=$worker'
# What the gate is checking, step by step, while it runs (pr-gate-progress.sh). Best effort.
gate_progress_watch "$log" "$steps_tsv" "$gate_worker" "$owner" "$repo" "$sha" \
  "$(gate_planned_path "$owner" "$repo")" "$step_sources" "$checks_url" >/dev/null 2>&1 &
progress_watcher=$!
worker_exit=0
wait "$gate_worker" || worker_exit=$?
gate_worker=""
kill "$progress_watcher" 2>/dev/null || true
wait "$progress_watcher" 2>/dev/null || true
gate_steps_record "$log" "$steps_tsv" || true
date +%s >"$gate_attempt_dir/steps.end"
state=success
((worker_exit == 0)) || state=failure
((worker_exit != 124 && worker_exit != 137)) || state=timed_out
after_inputs="$gate_attempt_dir/after-inputs.json"
if ! PATH="$RECIPE_PATH" gate_inputs "$after_inputs" \
  || ! jq -e --slurpfile after "$after_inputs" '.inputs == $after[0]' "$gate_receipt" >/dev/null; then
  state=inputs_changed
fi
gate_finish "$state" "$worker_exit" "$log"
# Only an approved commit on its way to main feeds the shared cache: a green merge-queue replay or a
# green main-health gate. A pull-request head is unreviewed until it is queued, so its outputs are
# read from the store but never written to it. Every other outcome deletes the slot's copy, which
# also keeps the disk to one cache per repository plus one per busy slot.
if ((build_cache)); then
  if [[ "$state" == success ]] && { [[ "$qref" =~ ^refs/queue/ ]] || ((main_health)); }; then
    publish_rc=0
    gate_golden_publish "$build_cache_store" "$build_cache_key" "$run/$repo/target/build-cache" \
      "$(jq -r '.id' "$gate_receipt")" || publish_rc=$?
    case "$publish_rc" in
      0) say "published $owner/$repo build cache as the shared version for its key";;
      2) say "$owner/$repo build cache is over the size limit; withdrawn, the next landing gate starts it fresh";;
      *) say "could not publish $owner/$repo build cache; the store keeps its current version";;
    esac
  fi
  rm -rf -- "$run/$repo/target/build-cache"
fi
gate_publish || die "terminal $state saved; publication recovery required in $gate_receipt"
seconds=$(( $(date +%s) - started_s ))
jq -nc --arg repo "$owner/$repo" --argjson pr "$number" --arg sha "$sha" --arg recipe "$recipe_name" \
  --arg conclusion "$state" --argjson exit_code "$worker_exit" --argjson seconds "$seconds" --arg at "$(date -u +%FT%TZ)" \
  --arg kind "$([[ "$main_health" == 1 ]] && printf main-health || printf pr)" \
  '{repo:$repo,pr:$pr,sha:$sha,recipe:$recipe,conclusion:$conclusion,exit_code:$exit_code,seconds:$seconds,finishedAt:$at,kind:$kind}' \
  | gate_atomic "$LAST_GATE"
heartbeat
say "recorded $owner/$repo $(gate_status_context "$owner" "$repo")=$state; exit $worker_exit; evidence $gate_receipt"
# Attempt evidence is retained with its log, including active and unpublished results.
# Age does not discharge a recovery obligation. Preservation-aware retention must be
# qualified separately before any journal or legacy log is removed.
# A recorded red result is the runner doing its job, not a fault: exit 0 so systemd does
# not show a healthy slot as failed. Runner faults still die non-zero.
exit 0
done
if ((GATE_FORGE_REUSE == 1 && ${#forge_adopted[@]})); then
  read -r owner repo number sha _ <<<"${forge_adopted[0]}"
  say "idle: re-proving $owner/$repo#$number at $sha here, whose result came from another host"
  candidates=("${forge_adopted[0]}")
  GATE_FORGE_REUSE=0
  continue
fi
break
done
heartbeat
say "no admitted head needs a new execution"
