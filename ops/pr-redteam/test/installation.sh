#!/usr/bin/env bash
# Installation must not activate review/merge or replace units under active custody, and must not
# write a credential or a site-specific credential path into the unit.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/home"
cat > "$t/bin/systemctl" <<'FIXTURE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$INSTALL_FIXTURE/calls"
case "$*" in
  *is-active*) [[ "$FIXTURE_UNIT_ACTIVE" == 1 ]] ;;
  # Real systemctl prints the state and exits 0 for a static unit too.
  *is-enabled*) printf '%s\n' "${FIXTURE_ENABLED_STATE:-static}"; [[ "${FIXTURE_ENABLED_STATE:-static}" != disabled ]] ;;
  '--user daemon-reload') exit 0 ;;
  *) echo 'unexpected activation command' >&2; exit 97 ;;
esac
FIXTURE
printf '#!/usr/bin/env bash\nexit 0\n' > "$t/bin/claude"
chmod +x "$t/bin/"*
run() { HOME="$t/home" PATH="$t/bin:$PATH" INSTALL_FIXTURE="$t" FIXTURE_UNIT_ACTIVE="$1" bash "$here/install.sh" > "$t/out" 2>&1; }
if run 0; then echo 'installation without site.env was accepted' >&2; exit 1; fi
grep -q 'requires EnvironmentFile=' "$t/out"
mkdir -p "$t/home/.config/pr-redteam"
printf 'JERYU_BASE=https://forge.invalid\nJERYU_TOKEN_FILE=%s/token\n' "$t" > "$t/home/.config/pr-redteam/site.env"
run 0
unit="$t/home/.config/systemd/user/pr-redteam.service"
# The merger credential path is site configuration: the unit may only point at the
# site's environment file, never assign REDTEAM_MERGE_TOKEN_FILE itself.
grep -q '^EnvironmentFile=-%h/.config/pr-redteam/merge.env$' "$unit"
# The forge origin and the approver credential path are site configuration too:
# every unit may only point at the site's environment file.
for staged in "$t/home/.config/systemd/user/pr-redteam.service" \
  "$t/home/.config/systemd/user/pr-redteam-heartbeat.service" \
  "$t/home/.config/systemd/user/pr-redteam-poke.service"; do
  grep -q '^EnvironmentFile=%h/.config/pr-redteam/site.env$' "$staged"
  if grep -Eq '^Environment=.*(JERYU_BASE|JERYU_TOKEN_FILE|REDTEAM_MERGE_TOKEN_FILE|REDTEAM_PRIORITY_FAMILIES)' "$staged"; then
    echo 'forbidden credential or site setting in a unit' >&2; exit 1
  fi
  if grep -Eq 'credentials/|\.pat' "$staged"; then echo 'forbidden credential or activation evidence' >&2; exit 1; fi
done
[[ "$(find "$t/home/.config/systemd/user" -type f | wc -l)" == 7 ]]
# The poke unit runs this directory's script, like the review and heartbeat units.
grep -q "^ExecStart=$here/pr-redteam poke\$" "$t/home/.config/systemd/user/pr-redteam-poke.service"
grep -q '^OnFailure=pr-redteam-notify@%n.service$' "$t/home/.config/systemd/user/pr-redteam.service"
grep -q '^OnFailure=pr-redteam-notify@%n.service$' "$t/home/.config/systemd/user/pr-redteam-heartbeat.service"
grep -q '^OnFailure=pr-redteam-notify@%n.service$' "$t/home/.config/systemd/user/pr-redteam-poke.service"
grep -q '^EnvironmentFile=-%h/.config/pr-redteam/site.env$' "$t/home/.config/systemd/user/pr-redteam-notify@.service"
grep -q "^ExecStart=$here/notify-failure %I\$" "$t/home/.config/systemd/user/pr-redteam-notify@.service"
if grep -Eq 'enable --now|start --no-block|disable|stop ' "$t/calls"; then echo 'forbidden credential or activation evidence' >&2; exit 1; fi
sha256sum "$t/home/.config/systemd/user/"* > "$t/before"
if run 1; then echo 'active installation was accepted' >&2; exit 1; fi
# A unit that is stopped but still enabled would start on its own: refused too.
if FIXTURE_ENABLED_STATE=enabled run 0; then echo 'enabled installation was accepted' >&2; exit 1; fi
sha256sum -c "$t/before" > /dev/null
if grep -Eq 'enable --now|start --no-block|disable|stop ' "$t/calls"; then echo 'forbidden credential or activation evidence' >&2; exit 1; fi

cat > "$t/bin/journalctl" <<'FIXTURE'
#!/usr/bin/env bash
printf 'journal for %s\n' "$*"
FIXTURE
chmod +x "$t/bin/journalctl"
PATH="$t/bin:$PATH" "$here/notify-failure" pr-redteam.service > "$t/notify-empty-out" 2> "$t/notify-empty-err"
grep -q 'no NOTIFY_COMMAND or NOTIFY_WEBHOOK_URL configured for pr-redteam.service' "$t/notify-empty-err"
NOTIFY_COMMAND='cat > "$INSTALL_FIXTURE/notification"' INSTALL_FIXTURE="$t" PATH="$t/bin:$PATH" \
  "$here/notify-failure" pr-redteam-heartbeat.service > "$t/notify-command-out" 2>&1
grep -q 'pr-redteam unit failed: pr-redteam-heartbeat.service' "$t/notification"
grep -q 'journal for --user -u pr-redteam-heartbeat.service' "$t/notification"
echo 'INACTIVE INSTALLATION PASS'
