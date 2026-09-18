#!/usr/bin/env bash
# Install pr-redteam as a systemd --user timer on this host and start a first pass.
# Run it from wherever pr-redteam lives (a checkout of this repo is fine); the unit is written with
# that absolute path, so a `git pull` in the checkout updates what the timer runs.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
[ -x "$here/pr-redteam" ] || { echo "no executable pr-redteam next to $0" >&2; exit 1; }
command -v claude >/dev/null || [ -x "$HOME/.local/bin/claude" ] || { echo "claude CLI not found" >&2; exit 1; }

units="$HOME/.config/systemd/user"
mkdir -p "$units"
# The review unit is written with this directory's path; replacing a symlink from an older install is fine.
rm -f "$units/pr-redteam.service" "$units/pr-redteam.timer"
sed "s#@REDTEAM_DIR@#$here#g" "$here/systemd/pr-redteam.service" >"$units/pr-redteam.service"
cp "$here/systemd/pr-redteam.timer" "$units/pr-redteam.timer"
rm -f "$units/pr-redteam-heartbeat.service" "$units/pr-redteam-heartbeat.timer"
sed "s#@REDTEAM_DIR@#$here#g" "$here/systemd/pr-redteam-heartbeat.service" >"$units/pr-redteam-heartbeat.service"
cp "$here/systemd/pr-redteam-heartbeat.timer" "$units/pr-redteam-heartbeat.timer"
systemctl --user daemon-reload
systemctl --user enable --now pr-redteam.timer
systemctl --user enable --now pr-redteam-heartbeat.timer
systemctl --user start --no-block pr-redteam.service
loginctl show-user "$USER" -p Linger | grep -q yes \
  || echo "note: linger is off; run 'sudo loginctl enable-linger $USER' so the timer survives logout"
echo "installed from $here; follow with: journalctl --user -u pr-redteam -f"
