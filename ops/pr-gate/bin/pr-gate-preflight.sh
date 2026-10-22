#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pr-gate-preflight.sh — a read-only look at a gate host before a release (ADR 0019).
# Run as `pr-gate-runner.sh --preflight`. It takes no slot lock, writes nothing under the runner
# home, posts nothing, and gives up on the forge after PR_GATE_PREFLIGHT_BUDGET seconds (default 90),
# so it finishes inside two minutes whatever the forge does. It reports three things:
#
#   1. stale slot locks: .git/index.lock files older than PR_GATE_PREFLIGHT_LOCK_AGE_MIN minutes
#      (default 120) under the slot trees (<runner home>/tree*). One such file made every gate of a
#      slot die silently after "preparing".
#   2. pinned-tool drift: each tool in the site's PR_GATE_PINNED_TOOLS_FILE (data, one tool per
#      line: `name package reviewed-version[,version...] [sha256]`) must resolve, carry the pinned
#      digest when one is given, and come from an installed package version that was reviewed.
#      An unattended upgrade of the package shows here.
#   3. each family main's latest <repo>/required status.
#
# Exit 0: nothing to fix. Exit 1: at least one finding. Exit 2: not configured.
# ---------------------------------------------------------------------------
set -uo pipefail
PREFLIGHT_SCRIPT="$(realpath -- "${BASH_SOURCE[0]}")"
# shellcheck source=ops/pr-gate/bin/pr-gate-config.sh
source "$(dirname -- "$PREFLIGHT_SCRIPT")/pr-gate-config.sh"
pr_gate_load_config
# shellcheck source=ops/pr-gate/bin/pr-gate-state.sh
source "$(dirname -- "$PREFLIGHT_SCRIPT")/pr-gate-state.sh"

HOME_DIR="${GATE_RUNNER_HOME:-$HOME/gate-runner}"
TOOLS="${GATE_RUNNER_TOOLS:-$HOME_DIR/governed-tools/bin}"
BASE="${JERYU_BASE:-${PR_GATE_FORGE_URL:-}}"; BASE="${BASE%/}"
TOKEN_FILE="$(pr_gate_path "${JERYU_TOKEN_FILE:-}")"
PINNED_FILE="$(pr_gate_path "${PR_GATE_PINNED_TOOLS_FILE:-}")"
LOCK_AGE_MIN="${PR_GATE_PREFLIGHT_LOCK_AGE_MIN:-120}"
BUDGET="${PR_GATE_PREFLIGHT_BUDGET:-90}"
for n in "$LOCK_AGE_MIN" "$BUDGET"; do
  [[ "$n" =~ ^[0-9]{1,6}$ ]] || { printf 'pr-gate-preflight: %s is not a number\n' "$n" >&2; exit 2; }
done
PRIMARY_OWNER="${PR_GATE_PRIMARY_OWNER:-}"
findings=0
deadline=$((SECONDS + BUDGET))
ok() { printf 'ok    %s\n' "$*"; }
bad() { findings=$((findings + 1)); printf 'FIND  %s\n' "$*"; }
note() { printf 'note  %s\n' "$*"; }

# 1. stale index locks under the slot trees
printf '== stale slot locks (.git/index.lock older than %s min)\n' "$LOCK_AGE_MIN"
stale=0 trees=0
for tree in "$HOME_DIR"/tree "$HOME_DIR"/tree-*; do
  [[ -d "$tree" && ! -L "$tree" ]] || continue
  trees=$((trees + 1))
  while IFS= read -r lock; do
    [[ -n "$lock" ]] || continue
    stale=$((stale + 1))
    bad "stale lock $lock (modified $(date -u -d "@$(stat -c %Y -- "$lock")" +%FT%TZ)); remove it once no git runs there"
  done < <(find "$tree" -maxdepth 5 -path '*/.git/index.lock' -type f -mmin "+$LOCK_AGE_MIN" 2>/dev/null)
done
((stale > 0)) || ok "no stale index.lock in $trees tree(s) under $HOME_DIR"

# 2. pinned tools
printf '== pinned tools\n'
if [[ -z "$PINNED_FILE" ]]; then
  note "PR_GATE_PINNED_TOOLS_FILE is not configured; no tool is checked"
elif [[ ! -r "$PINNED_FILE" || ! -f "$PINNED_FILE" ]]; then
  bad "pinned-tools file $PINNED_FILE is not readable"
else
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    read -r name package versions digest extra <<<"$line"
    [[ -n "$name" ]] || continue
    if [[ ! "$name" =~ ^[A-Za-z0-9._+-]+$ || ! "$package" =~ ^[a-z0-9][a-z0-9.+-]*$ || -z "$versions" || -n "$extra" \
          || ( -n "$digest" && ! "$digest" =~ ^[0-9a-f]{64}$ ) ]]; then
      bad "pinned-tools line is malformed: $line"; continue
    fi
    exe=""
    if [[ -x "$TOOLS/$name" ]]; then exe="$TOOLS/$name"; else exe="$(PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" command -v -- "$name" 2>/dev/null || true)"; fi
    if [[ -z "$exe" ]]; then bad "$name: not found"; continue; fi
    if [[ -n "$digest" ]]; then
      have="$(sha256sum -- "$exe" 2>/dev/null | cut -c1-64)"
      [[ "$have" == "$digest" ]] || { bad "$name: $exe has digest ${have:-unreadable}, pinned $digest"; continue; }
    fi
    installed="$(dpkg-query -W -f='${db:Status-Abbrev}|${Version}' -- "$package" 2>/dev/null || true)"
    if [[ "${installed%%|*}" != "ii" && "${installed%%|*}" != "ii " ]]; then bad "$name: package $package is not installed"; continue; fi
    installed="${installed#*|}"
    if [[ ",$versions," == *",$installed,"* ]]; then
      ok "$name: $package $installed is reviewed"
    else
      bad "$name: $package is $installed, reviewed: $versions (an upgrade not yet reviewed?)"
    fi
  done <"$PINNED_FILE"
fi

# 3. each family main's latest <repo>/required
printf '== family mains\n'
repos="${GATE_RUNNER_REPOS:-}"
if [[ -z "${repos// }" || "$repos" == auto ]]; then
  repos=""
  for cache in "$HOME_DIR"/cache/protected-*; do
    [[ -f "$cache" ]] && repos+="$(cat -- "$cache" 2>/dev/null) "
  done
fi
if [[ -z "${repos// }" ]]; then
  note "no repository known (GATE_RUNNER_REPOS, or a runner tick has not yet discovered them)"
elif [[ -z "$BASE" || ! -r "$TOKEN_FILE" || ! -f "$TOKEN_FILE" ]]; then
  bad "cannot read family mains: PR_GATE_FORGE_URL or JERYU_TOKEN_FILE is not usable"
else
  auth="$(mktemp "${TMPDIR:-/tmp}/gate-preflight-auth.XXXXXX")" || exit 2
  trap 'rm -f -- "$auth"' EXIT
  chmod 0600 "$auth"
  printf 'header = "Authorization: Bearer %s"\n' "$(cat -- "$TOKEN_FILE")" >"$auth"
  get() { # path -> body on stdout; fails on anything but 200
    local left=$((deadline - SECONDS)) out code
    ((left > 0)) || return 2
    out="$(curl --silent --max-time "$((left < 15 ? left : 15))" --config "$auth" -H 'Accept: application/json' \
      -w '\n%{http_code}' "$BASE$1" 2>/dev/null)" || return 1
    code="${out##*$'\n'}"
    [[ "$code" == 200 ]] || return 1
    printf '%s' "${out%$'\n'*}"
  }
  for q in $repos; do
    if [[ "$q" != */* ]]; then
      [[ -n "$PRIMARY_OWNER" ]] || { bad "repository $q has no owner and PR_GATE_PRIMARY_OWNER is not configured"; continue; }
      q="$PRIMARY_OWNER/$q"
    fi
    owner="${q%%/*}" repo="${q#*/}"
    if ((SECONDS >= deadline)); then bad "$q: not checked, the $BUDGET s budget ran out"; continue; fi
    body="$(get "/api/v3/repos/$owner/$repo/branches/main")"; rc=$?
    sha=""; ((rc != 0)) || sha="$(jq -r '.commit.sha // .sha // ""' <<<"$body" 2>/dev/null)"
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then bad "$q: cannot resolve main"; continue; fi
    body="$(get "/repos/$owner/$repo/commits/$sha/status")"; rc=$?
    if ((rc != 0)); then bad "$q: cannot read the statuses of main ${sha:0:12}"; continue; fi
    context="$(gate_required_context "$owner" "$repo")"
    state="$(jq -r --arg c "$context" '[.statuses[]? | select(.context == $c)] | sort_by(.updated_at // .created_at) | last | .state // "none"' <<<"$body" 2>/dev/null)"
    case "$state" in
      success) ok "$q main ${sha:0:12}: $context success";;
      none) bad "$q main ${sha:0:12}: no $context status";;
      *) bad "$q main ${sha:0:12}: $context is $state";;
    esac
  done
fi

printf '== %s finding(s)\n' "$findings"
((findings == 0))
