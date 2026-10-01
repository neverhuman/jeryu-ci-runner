#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pr-gate-install.sh — keep the installed gate runner equal to its source branch.
#
# Every runner fix used to wait for someone to copy it onto the gate host by hand,
# and a copy made while a gate was running could fail that gate. This runs from its
# own timer (pr-gate-install.timer, every 10 minutes):
#
#   1. refresh the gate's source branch (PR_GATE_SOURCE_URL, branch PR_GATE_SOURCE_BRANCH,
#      default main) in the installer's own bare mirror -- the only source it trusts: a
#      protected branch, never another branch or a working tree;
#   2. compare each managed file under PR_GATE_SOURCE_SUBDIR (default ops/pr-gate) there --
#      bin/pr-gate-*.sh and systemd/pr-gate-*.{service,timer} -- with the installed copy;
#   3. if the runner, its state library or its config library differs, drain first: stop every
#      pr-gate-runner@N.timer and wait until no runner process is left (at most
#      GATE_INSTALL_DRAIN_SECONDS, default 45 minutes, else install nothing);
#   4. install each differing file atomically, keeping the old copy as
#      <file>.<old-commit>-pre-<new-commit>.bak, reload systemd if a unit
#      changed, enable any managed singleton timer, restart the slot timers;
#   5. record the installed commit in installed-main.json, with its version
#      `pr-gate <VERSION>` read from <subdir>/VERSION at that commit (e.g. `pr-gate 1.0.0`): the
#      gate component is versioned on its own, independent of the repository's release tags.
#
# Every run (install or verify) also records what the gate evaluates with in tools.json: each
# executable in the governed tool dir and the host's governed jankurai, with version and sha256.
# Heartbeats read that file (gate_runner_tools in pr-gate-state.sh); hashing ~80 MB binaries is too
# slow for them to do it themselves.
#
# Merges within one interval become one install, and so one re-gate round.
# It never approves, merges, pushes or touches a gate's evidence.
# ---------------------------------------------------------------------------
set -euo pipefail
# Site configuration (source URL, branch, governed jankurai): see pr-gate-config.sh.
# shellcheck source=ops/pr-gate/bin/pr-gate-config.sh
source "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/pr-gate-config.sh"
pr_gate_load_config
HOME_DIR="${GATE_RUNNER_HOME:-$HOME/gate-runner}"
SOURCE_URL="${PR_GATE_SOURCE_URL:-}"
BRANCH="${PR_GATE_SOURCE_BRANCH:-main}"
SUBDIR="${PR_GATE_SOURCE_SUBDIR:-ops/pr-gate}"
SUBDIR="${SUBDIR%/}"
MIRROR="$(pr_gate_path "${GATE_INSTALL_MIRROR:-$HOME_DIR/source/pr-gate.git}")"
BIN="${GATE_INSTALL_BIN:-$HOME_DIR/bin}"
UNITS="${GATE_INSTALL_UNITS:-$HOME/.config/systemd/user}"
DRAIN_SECONDS="${GATE_INSTALL_DRAIN_SECONDS:-2700}"
STATE="$HOME_DIR/installed-main.json"   # also read by gate_runner_code (pr-gate-state.sh) for heartbeats
TOOLS_STATE="$HOME_DIR/tools.json"      # read by gate_runner_tools (pr-gate-state.sh) for heartbeats
TOOLS_DIR="${GATE_RUNNER_TOOLS:-$HOME_DIR/governed-tools/bin}"   # the runner's $TOOLS
# The host's governed jankurai, recorded as jankurai@governed when set.
GOVERNED_JANKURAI="$(pr_gate_path "${PR_GATE_GOVERNED_JANKURAI:-}")"
# Managed singleton timers: enabled when their unit is installed. Slot timers are instances and are
# only stopped and started around a drain, never enabled or disabled here.
SINGLETON_TIMERS="pr-gate-heartbeat.timer pr-gate-install.timer pr-gate-advisory-refresh.timer pr-gate-grype-db-refresh.timer pr-gate-wake.timer"

say() { printf '[gate-install %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ && "$BRANCH" != *..* ]] || { say "PR_GATE_SOURCE_BRANCH $BRANCH is not a branch name"; exit 2; }
[[ "$SUBDIR" =~ ^[A-Za-z0-9._/-]+$ && "$SUBDIR" != *..* && "$SUBDIR" != /* ]] || { say "PR_GATE_SOURCE_SUBDIR $SUBDIR is not a relative path"; exit 2; }
mkdir -p "$HOME_DIR"
exec 9>"$HOME_DIR/.install.lock"
flock -n 9 || { say "another install is running"; exit 0; }

# 0. what the gate evaluates with -> tools.json, on every run. Never fatal.
tool_version() { # executable -> first line of its --version (or `version`), its file name prefix stripped
  local exe=$1 name out arg line
  name=$(basename -- "$exe")
  for arg in --version version; do
    out=$(cd / && timeout -k 2 5 "$exe" "$arg" </dev/null 2>/dev/null) || continue
    line=$(printf '%s\n' "$out" | sed -n '/[^[:space:]]/{p;q}' | tr -d '\000-\037\177')
    line=$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"$line")
    [[ "${line,,}" == "${name,,}"[[:space:]]* ]] && line=$(sed -E 's/^[^[:space:]]+[[:space:]]+//' <<<"$line")
    [[ -n "$line" ]] || continue
    printf '%s' "${line:0:100}"; return 0
  done
  return 1
}
tool_entry() { # executable name -> one tools[] entry, or nothing
  local exe=$1 name=$2 version sha
  [[ "$name" =~ ^[a-z0-9._@-]{1,64}$ && -f "$exe" && -x "$exe" ]] || return 0
  sha=$(sha256sum -- "$exe" 2>/dev/null | cut -d' ' -f1) || sha=""
  version=$(tool_version "$exe") || version=""
  jq -nc --arg n "$name" --arg v "$version" --arg s "$sha" \
    '{name:$n} + (if $v != "" then {version:$v} else {} end) + (if ($s|test("^[0-9a-f]{64}$")) then {sha256:$s} else {} end)'
}
record_tools() {
  local f name tmp entries=()
  if [[ -d "$TOOLS_DIR" ]]; then
    for f in "$TOOLS_DIR"/*; do
      name=$(basename -- "$f"); name=${name,,}
      entries+=("$(tool_entry "$f" "$name")")
    done
  fi
  entries+=("$(tool_entry "$GOVERNED_JANKURAI" jankurai@governed)")
  tmp="$TOOLS_STATE.new.$$"
  printf '%s\n' "${entries[@]}" | jq -sc --arg at "$(date -u +%FT%TZ)" \
    '{generated_at:$at, tools:(map(select(type == "object")) | (map(select(.name == "jankurai@governed")) + map(select(.name != "jankurai@governed")))
       | reduce .[] as $t ([]; if any(.[]; .name == $t.name) then . else . + [$t] end) | .[0:32] | sort_by(.name))}' >"$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$TOOLS_STATE"
}
record_tools || say "could not record the gate's tools"

[[ -n "$SOURCE_URL" ]] || { say "PR_GATE_SOURCE_URL is not configured (set it in $PR_GATE_CONFIG_FILE); nothing installed"; exit 2; }

# 1. the source branch, in the installer's own bare mirror (under its lock). A mirror whose origin is
# not the configured source is pointed at it, so changing the source needs no hand step.
mkdir -p "$(dirname -- "$MIRROR")"
exec 8>"$MIRROR.lock"; flock 8
if [[ ! -d "$MIRROR" ]]; then
  if ! { git init --quiet --bare "$MIRROR" && git -C "$MIRROR" remote add origin "$SOURCE_URL"; }; then
    rm -rf -- "$MIRROR"; say "cannot create the source mirror; nothing installed"; exit 0
  fi
elif [[ "$(git -C "$MIRROR" remote get-url origin 2>/dev/null)" != "$SOURCE_URL" ]]; then
  git -C "$MIRROR" remote set-url origin "$SOURCE_URL" 2>/dev/null || git -C "$MIRROR" remote add origin "$SOURCE_URL"
fi
git -C "$MIRROR" fetch --quiet --prune --no-tags origin "+refs/heads/$BRANCH:refs/heads/$BRANCH" \
  || { say "cannot refresh $BRANCH from the configured source; nothing installed"; exit 0; }
exec 8>&-
commit=$(git -C "$MIRROR" rev-parse --verify "refs/heads/$BRANCH^{commit}")
short=${commit:0:7}
previous=$(jq -r '.commit // "unknown"' "$STATE" 2>/dev/null || echo unknown)
previous=${previous:0:7}
# The component's version for heartbeats: `pr-gate <VERSION>` from <subdir>/VERSION at this commit
# (semver; see README.md). Never fatal: a missing or malformed VERSION records no version.
version=$(git -C "$MIRROR" show "$commit:$SUBDIR/VERSION" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]{1,40})?$ ]] && version="pr-gate $version" || version=""

# 2. which managed files differ. Destination by source path.
declare -A dest=()
while IFS= read -r src; do
  dest["$src"]="$BIN/$(basename "$src")"
done < <(git -C "$MIRROR" ls-tree --name-only "$commit" "$SUBDIR/bin/" | grep -E '/pr-gate-[A-Za-z0-9._-]+\.sh$' || true)
while IFS= read -r unit; do
  dest["$unit"]="$UNITS/$(basename "$unit")"
done < <(git -C "$MIRROR" ls-tree --name-only "$commit" "$SUBDIR/systemd/" | grep -E '/pr-gate-[^/]+\.(service|timer)$' || true)
((${#dest[@]} > 0)) || { say "$BRANCH $short has no $SUBDIR/bin/pr-gate-*.sh; nothing installed"; exit 0; }

stage=$(mktemp -d); trap 'rm -rf -- "$stage"' EXIT
changed=() drain=0 units_changed=0
for src in "${!dest[@]}"; do
  git -C "$MIRROR" cat-file -e "$commit:$src" 2>/dev/null || continue
  git -C "$MIRROR" show "$commit:$src" >"$stage/${src//\//_}"
  if ! cmp -s "$stage/${src//\//_}" "${dest[$src]}" 2>/dev/null; then
    changed+=("$src")
    case "$src" in "$SUBDIR/bin/pr-gate-runner.sh"|"$SUBDIR/bin/pr-gate-state.sh"|"$SUBDIR/bin/pr-gate-config.sh") drain=1;; esac
    [[ "$src" != "$SUBDIR/systemd/"* ]] || units_changed=1
  fi
done
if ((${#changed[@]} == 0)); then
  # Nothing to install. A new commit gets a fresh verified record; the same commit keeps its record
  # and only has its version filled in or corrected (how hosts installed before versions, or with
  # an older version form, get the current one).
  if [[ "$previous" != "$short" ]]; then
    record=$(jq -n --arg c "$commit" --arg at "$(date -u +%FT%TZ)" --arg v "$version" \
      '{commit:$c,verified_at:$at} + (if $v != "" then {version:$v} else {} end)') || exit 0
  elif [[ -n "$version" && "$(jq -r '.version // ""' "$STATE" 2>/dev/null)" != "$version" ]]; then
    record=$(jq --arg v "$version" '. + {version:$v}' "$STATE" 2>/dev/null) || exit 0
  else
    exit 0
  fi
  printf '%s\n' "$record" >"$STATE.new.$$" && mv -f -- "$STATE.new.$$" "$STATE"
  exit 0
fi
say "$BRANCH $short differs from the installed runner in: ${changed[*]}"
for src in "${changed[@]}"; do
  [[ "$src" != *.sh ]] || bash -n "$stage/${src//\//_}" || { say "FAIL: $src from $short does not parse; nothing installed"; exit 1; }
done

# 3. drain before replacing the runner or its state library.
slots=$(systemctl --user list-units --no-legend --plain --all 'pr-gate-runner@*.timer' \
  | sed -n 's/^pr-gate-runner@\([0-9]\+\)\.timer.*/\1/p' | sort -un | tr '\n' ' ')
resume() { local i; for i in $slots; do systemctl --user start "pr-gate-runner@$i.timer" || true; done; }
if ((drain)); then
  for i in $slots; do systemctl --user stop "pr-gate-runner@$i.timer"; done
  trap 'resume; rm -rf -- "$stage"' EXIT
  deadline=$(( $(date +%s) + DRAIN_SECONDS ))
  while pgrep -f "$BIN/pr-gate-runner.sh" >/dev/null; do
    if (( $(date +%s) >= deadline )); then say "slots still busy after ${DRAIN_SECONDS}s; nothing installed, retrying next interval"; exit 0; fi
    sleep 10
  done
  say "slots drained (${slots:-none})"
fi

# 4. install, each file atomically with its predecessor kept.
for src in "${changed[@]}"; do
  target=${dest[$src]}
  mkdir -p "$(dirname "$target")"
  [[ ! -e "$target" ]] || cp -p -- "$target" "$target.$previous-pre-$short.bak"
  install -m "$([[ "$src" == *.sh ]] && echo 0755 || echo 0644)" "$stage/${src//\//_}" "$target.new.$$"
  mv -f -- "$target.new.$$" "$target"
  say "installed $src"
done
if ((units_changed)); then
  systemctl --user daemon-reload
  for timer in $SINGLETON_TIMERS; do
    [[ -e "$UNITS/$timer" ]] && systemctl --user enable --now "$timer" >/dev/null 2>&1 || true
  done
fi
resume
trap 'rm -rf -- "$stage"' EXIT

# 5. record it.
jq -n --arg c "$commit" --arg p "$previous" --arg at "$(date -u +%FT%TZ)" --arg v "$version" \
  --argjson files "$(printf '%s\n' "${changed[@]}" | jq -R . | jq -s .)" \
  '{commit:$c,previous:$p,installed_at:$at,files:$files} + (if $v != "" then {version:$v} else {} end)' >"$STATE"
say "installed $BRANCH $short${version:+ ($version)} (was $previous)"
