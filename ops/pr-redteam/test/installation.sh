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
  *is-active*) [[ "$FIXTURE_UNIT_ACTIVE" == 1 || ( "$*" == *pr-redteam-merge@jeryu:* && "${FIXTURE_INSTANCE_ACTIVE:-0}" == 1 ) || ( "$*" == *pr-redteam-review@jeryu:* && "${FIXTURE_REVIEW_INSTANCE_ACTIVE:-0}" == 1 ) ]] ;;
  # Real systemctl prints the state and exits 0 for a static unit too.
  *is-enabled*) printf '%s\n' "${FIXTURE_ENABLED_STATE:-static}"; [[ "${FIXTURE_ENABLED_STATE:-static}" != disabled ]] ;;
  '--user daemon-reload') exit 0 ;;
  *list-units*pr-redteam-merge@*) [[ "${FIXTURE_INSTANCE_ACTIVE:-0}" == 0 ]] || echo 'pr-redteam-merge@jeryu:fixture:107:1111111111111111111111111111111111111111.service loaded active running'; exit 0 ;;
  *list-units*pr-redteam-review@*) [[ "${FIXTURE_REVIEW_INSTANCE_ACTIVE:-0}" == 0 ]] || echo 'pr-redteam-review@jeryu:fixture:107:1111111111111111111111111111111111111111.service loaded active running'; exit 0 ;;
  *) echo 'unexpected activation command' >&2; exit 97 ;;
esac
FIXTURE
printf '#!/usr/bin/env bash\nexit 0\n' > "$t/bin/claude"
chmod +x "$t/bin/"*
run() { HOME="$t/home" PATH="$t/bin:$PATH" INSTALL_FIXTURE="$t" FIXTURE_UNIT_ACTIVE="$1" bash "$here/install.sh" > "$t/out" 2>&1; }
if run 0; then echo 'installation without site.env was accepted' >&2; exit 1; fi
grep -q 'requires EnvironmentFile=' "$t/out"
mkdir -p "$t/home/.config/pr-redteam"
printf 'JERYU_BASE=https://forge.invalid\nJERYU_TOKEN_FILE=%s/token\nREDTEAM_CLAUDE=%s/bin/claude\nREDTEAM_CLAUDE_VERSION=9.9.9\n' "$t" "$t" > "$t/home/.config/pr-redteam/site.env"
touch "$t/token"
run 0
unit="$t/home/.config/systemd/user/pr-redteam.service"
# The merger credential path is site configuration: the unit may only point at the
# site's environment file, never assign REDTEAM_MERGE_TOKEN_FILE itself.
grep -q '^EnvironmentFile=-%h/.config/pr-redteam/merge.env$' "$unit"
# The forge origin and the approver credential path are site configuration too:
# every unit may only point at the site's environment file.
for staged in "$t/home/.config/systemd/user/pr-redteam.service" \
  "$t/home/.config/systemd/user/pr-redteam-heartbeat.service" \
  "$t/home/.config/systemd/user/pr-redteam-poke.service" \
  "$t/home/.config/systemd/user/pr-redteam-merge@.service" \
  "$t/home/.config/systemd/user/pr-redteam-watch.service" \
  "$t/home/.config/systemd/user/pr-redteam-review@.service"; do
  grep -q '^EnvironmentFile=%h/.config/pr-redteam/site.env$' "$staged"
  if grep -Eq '^Environment=.*(JERYU_BASE|JERYU_TOKEN_FILE|REDTEAM_MERGE_TOKEN_FILE|REDTEAM_PRIORITY_FAMILIES)' "$staged"; then
    echo 'forbidden credential or site setting in a unit' >&2; exit 1
  fi
  if grep -Eq 'credentials/|\.pat' "$staged"; then echo 'forbidden credential or activation evidence' >&2; exit 1; fi
done
[[ "$(find "$t/home/.config/systemd/user" -type f | wc -l)" == 10 ]]
grep -q "^ExecStart=$here/pr-redteam _merge_scoped %i\$" "$t/home/.config/systemd/user/pr-redteam-merge@.service"
! grep -q 'merge.env' "$t/home/.config/systemd/user/pr-redteam-poke.service"
# The event-driven reviewer reviews and publishes; it lands nothing, so neither the watcher nor a
# scoped review may carry the merger environment.
! grep -q 'merge.env' "$t/home/.config/systemd/user/pr-redteam-watch.service"
! grep -q 'merge.env' "$t/home/.config/systemd/user/pr-redteam-review@.service"
grep -q "^ExecStart=$here/pr-redteam watch\$" "$t/home/.config/systemd/user/pr-redteam-watch.service"
grep -q "^ExecStart=$here/pr-redteam _review_scoped %i\$" "$t/home/.config/systemd/user/pr-redteam-review@.service"
grep -q '^OnFailure=pr-redteam-notify@%n.service$' "$t/home/.config/systemd/user/pr-redteam-watch.service"
grep -q '^OnFailure=pr-redteam-notify@%n.service$' "$t/home/.config/systemd/user/pr-redteam-review@.service"
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
if FIXTURE_INSTANCE_ACTIVE=1 run 0; then echo 'active merge instance was accepted' >&2; exit 1; fi
if FIXTURE_REVIEW_INSTANCE_ACTIVE=1 run 0; then echo 'active review instance was accepted' >&2; exit 1; fi
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
NOTIFY_COMMAND='test -n "$PR_REDTEAM_NOTIFY_BODY_FILE" && test -n "$PR_REDTEAM_NOTIFY_BODY" && cat > "$INSTALL_FIXTURE/notification-file-ok" && cmp "$PR_REDTEAM_NOTIFY_BODY_FILE" "$INSTALL_FIXTURE/notification-file-ok" && test "$PR_REDTEAM_NOTIFY_BODY" = "$(cat "$PR_REDTEAM_NOTIFY_BODY_FILE")"' \
  INSTALL_FIXTURE="$t" PATH="$t/bin:$PATH" \
  "$here/notify-failure" pr-redteam-poke.service > "$t/notify-file-out" 2>&1
grep -q 'pr-redteam unit failed: pr-redteam-poke.service' "$t/notification-file-ok"
cat > "$t/bin/journalctl" <<'FIXTURE'
#!/usr/bin/env bash
printf 'line one\nreviewer token is REVIEW-TOKEN-7f3a\nline three\n'
FIXTURE
chmod +x "$t/bin/journalctl"
printf 'REVIEW-TOKEN-7f3a\n' > "$t/token"
NOTIFY_COMMAND='cat > "$INSTALL_FIXTURE/notification-redacted"' INSTALL_FIXTURE="$t" PATH="$t/bin:$PATH" \
  JERYU_TOKEN_FILE="$t/token" "$here/notify-failure" pr-redteam.service > "$t/notify-redacted-out" 2> "$t/notify-redacted-err"
grep -q 'journal omitted: configured token value appeared' "$t/notification-redacted"
! grep -q 'REVIEW-TOKEN-7f3a' "$t/notification-redacted"
grep -q 'configured token value appeared in notification' "$t/notify-redacted-err"
cat > "$t/bin/journalctl" <<'FIXTURE'
#!/usr/bin/env bash
printf '0123456789abcdef\n0123456789abcdef\n'
FIXTURE
chmod +x "$t/bin/journalctl"
NOTIFY_COMMAND='cat > "$INSTALL_FIXTURE/notification-capped"' INSTALL_FIXTURE="$t" PATH="$t/bin:$PATH" \
  NOTIFY_MAX_BODY_BYTES=64 "$here/notify-failure" pr-redteam.service > "$t/notify-capped-out" 2>&1
[[ "$(wc -c < "$t/notification-capped")" -le 64 ]]
# A secret after the body cap still suppresses the entire captured journal.
cat >"$t/bin/journalctl" <<'FIXTURE'
#!/usr/bin/env bash
printf '%200s\nREVIEW-TOKEN-7f3a\n' x
FIXTURE
NOTIFY_COMMAND='cat > "$INSTALL_FIXTURE/notification-after-cap"' INSTALL_FIXTURE="$t" PATH="$t/bin:$PATH" \
  JERYU_TOKEN_FILE="$t/token" NOTIFY_MAX_BODY_BYTES=100 "$here/notify-failure" pr-redteam.service >"$t/notify-after-cap-out" 2>&1
grep -q 'journal omitted' "$t/notification-after-cap"
! grep -q 'REVIEW-TOKEN-7f3a' "$t/notification-after-cap"
# Both ordinary EnvironmentFile quote forms name the same installed executable.
for quote in '"' "'"; do
  printf 'JERYU_BASE=https://forge.invalid\nJERYU_TOKEN_FILE=%s/token\nREDTEAM_CLAUDE=%s%s/bin/claude%s\nREDTEAM_CLAUDE_VERSION=9.9.9\n' \
    "$t" "$quote" "$t" "$quote" >"$t/home/.config/pr-redteam/site.env"
  run 0
done
echo 'INACTIVE INSTALLATION PASS'
