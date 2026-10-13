#!/usr/bin/env bash
# Stage pr-redteam user units; activation belongs to the existing service owner.
# No credential is written here: the unit reads the merger credential's path from
# ~/.config/pr-redteam/merge.env, which the service owner creates.
# Run from the custodied source directory. Every later source change requires
# the service owner's stopped handoff, qualification and separate activation.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
[ -x "$here/pr-redteam" ] || { echo "no executable pr-redteam next to $0" >&2; exit 1; }

units="$HOME/.config/systemd/user"
required_environment_files() {
  local file="$1" env_file
  while IFS= read -r env_file; do
    env_file="${env_file#EnvironmentFile=}"
    [[ "$env_file" == -* ]] && continue
    env_file="${env_file//%h/$HOME}"
    env_file="${env_file//@REDTEAM_DIR@/$here}"
    printf '%s\n' "$env_file"
  done < <(grep -E '^EnvironmentFile=' "$file" || true)
}

for source_unit in \
  "$here/systemd/pr-redteam.service" \
  "$here/systemd/pr-redteam-heartbeat.service" \
  "$here/systemd/pr-redteam-merge@.service" \
  "$here/systemd/pr-redteam-poke.service"; do
  while IFS= read -r env_file; do
    [ -f "$env_file" ] || {
      echo "$(basename "$source_unit") requires EnvironmentFile=$env_file; create it before installation" >&2
      exit 1
    }
  done < <(required_environment_files "$source_unit")
done

# Presence of the shared file alone is not enough: systemd treats an unset
# EnvironmentFile variable as an empty setting, and poke needs the same inputs
# as review to calculate the review identity.
site_env="$HOME/.config/pr-redteam/site.env"
for setting in JERYU_BASE JERYU_TOKEN_FILE REDTEAM_CLAUDE REDTEAM_CLAUDE_VERSION; do
  grep -Eq "^${setting}=.+$" "$site_env" || {
    echo "$site_env must define $setting before installation" >&2
    exit 1
  }
done
claude_path="$(sed -n 's/^REDTEAM_CLAUDE=//p' "$site_env" | tail -n 1)"
case "$claude_path" in
  \"*\") claude_path="${claude_path:1:${#claude_path}-2}" ;;
  \'*\') claude_path="${claude_path:1:${#claude_path}-2}" ;;
esac
[[ "$claude_path" == /* && -x "$claude_path" ]] || {
  echo "$site_env REDTEAM_CLAUDE must name an executable absolute path" >&2
  exit 1
}

# Replacing an active or enabled unit would change its next execution. Require the
# service owner to stop/disable it explicitly before staging replacement source.
for unit in pr-redteam.service pr-redteam.timer pr-redteam-heartbeat.service pr-redteam-heartbeat.timer \
  pr-redteam-poke.service pr-redteam-poke.timer pr-redteam-notify@.service pr-redteam-merge@.service; do
  # `is-enabled` also succeeds for a static unit (no [Install] section, as every
  # pr-redteam service is), so only states that start the unit on their own count.
  enabled_state="$(systemctl --user is-enabled "$unit" 2>/dev/null || true)"
  if systemctl --user is-active --quiet "$unit" ||
    [[ "$enabled_state" =~ ^(enabled|enabled-runtime|linked|linked-runtime|alias)$ ]]; then
    echo "$unit is active or enabled; its service owner must stop/disable it before installation" >&2
    exit 1
  fi
done
# Templates can have running instances even when the template itself is inactive.
instances="$(systemctl --user list-units --all --type=service --no-legend --plain 'pr-redteam-merge@*.service')"
while read -r instance _; do
  [ -n "$instance" ] || continue
  if systemctl --user is-active --quiet "$instance"; then
    echo "$instance is active; its service owner must stop it before installation" >&2
    exit 1
  fi
done <<<"$instances"
[[ "$here" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "unit source path contains unsupported characters" >&2; exit 1; }
mkdir -p "$units"
# The review unit is written with this directory's path; replacing a symlink from an older install is fine.
rm -f "$units/pr-redteam.service" "$units/pr-redteam.timer"
sed "s#@REDTEAM_DIR@#$here#g" "$here/systemd/pr-redteam.service" >"$units/pr-redteam.service"
cp "$here/systemd/pr-redteam.timer" "$units/pr-redteam.timer"
rm -f "$units/pr-redteam-heartbeat.service" "$units/pr-redteam-heartbeat.timer"
sed "s#@REDTEAM_DIR@#$here#g" "$here/systemd/pr-redteam-heartbeat.service" >"$units/pr-redteam-heartbeat.service"
cp "$here/systemd/pr-redteam-heartbeat.timer" "$units/pr-redteam-heartbeat.timer"
rm -f "$units/pr-redteam-poke.service" "$units/pr-redteam-poke.timer"
sed "s#@REDTEAM_DIR@#$here#g" "$here/systemd/pr-redteam-poke.service" >"$units/pr-redteam-poke.service"
cp "$here/systemd/pr-redteam-poke.timer" "$units/pr-redteam-poke.timer"
rm -f "$units/pr-redteam-merge@.service"
sed "s#@REDTEAM_DIR@#$here#g" "$here/systemd/pr-redteam-merge@.service" >"$units/pr-redteam-merge@.service"
rm -f "$units/pr-redteam-notify@.service"
sed "s#@REDTEAM_DIR@#$here#g" "$here/systemd/pr-redteam-notify@.service" >"$units/pr-redteam-notify@.service"
systemctl --user daemon-reload
echo "units staged from $here; no review, heartbeat or poke was started"
echo "the existing service owner must independently qualify and authorize activation"
