#!/usr/bin/env bash
# Stage pr-redteam user units; activation belongs to the existing service owner.
# No credential is written here: the unit reads the merger credential's path from
# ~/.config/pr-redteam/merge.env, which the service owner creates.
# Run from the custodied source directory. Every later source change requires
# the service owner's stopped handoff, qualification and separate activation.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
[ -x "$here/pr-redteam" ] || { echo "no executable pr-redteam next to $0" >&2; exit 1; }
command -v claude >/dev/null || [ -x "$HOME/.local/bin/claude" ] || { echo "claude CLI not found" >&2; exit 1; }

units="$HOME/.config/systemd/user"
# Replacing an active or enabled unit would change its next execution. Require the
# service owner to stop/disable it explicitly before staging replacement source.
for unit in pr-redteam.service pr-redteam.timer pr-redteam-heartbeat.service pr-redteam-heartbeat.timer; do
  if systemctl --user is-active --quiet "$unit" || systemctl --user is-enabled --quiet "$unit"; then
    echo "$unit is active or enabled; its service owner must stop/disable it before installation" >&2
    exit 1
  fi
done
[[ "$here" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "unit source path contains unsupported characters" >&2; exit 1; }
mkdir -p "$units"
# The review unit is written with this directory's path; replacing a symlink from an older install is fine.
rm -f "$units/pr-redteam.service" "$units/pr-redteam.timer"
sed "s#@REDTEAM_DIR@#$here#g" "$here/systemd/pr-redteam.service" >"$units/pr-redteam.service"
cp "$here/systemd/pr-redteam.timer" "$units/pr-redteam.timer"
rm -f "$units/pr-redteam-heartbeat.service" "$units/pr-redteam-heartbeat.timer"
sed "s#@REDTEAM_DIR@#$here#g" "$here/systemd/pr-redteam-heartbeat.service" >"$units/pr-redteam-heartbeat.service"
cp "$here/systemd/pr-redteam-heartbeat.timer" "$units/pr-redteam-heartbeat.timer"
systemctl --user daemon-reload
echo "units staged from $here; no review or heartbeat was started"
echo "the existing service owner must independently qualify and authorize activation"
