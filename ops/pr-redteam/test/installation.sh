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
  *is-active*|*is-enabled*) [[ "$FIXTURE_UNIT_ACTIVE" == 1 ]] ;;
  '--user daemon-reload') exit 0 ;;
  *) echo 'unexpected activation command' >&2; exit 97 ;;
esac
FIXTURE
printf '#!/usr/bin/env bash\nexit 0\n' > "$t/bin/claude"
chmod +x "$t/bin/"*
run() { HOME="$t/home" PATH="$t/bin:$PATH" INSTALL_FIXTURE="$t" FIXTURE_UNIT_ACTIVE="$1" bash "$here/install.sh" > "$t/out" 2>&1; }
run 0
unit="$t/home/.config/systemd/user/pr-redteam.service"
# The merger credential path is site configuration: the unit may only point at the
# site's environment file, never assign REDTEAM_MERGE_TOKEN_FILE itself.
grep -q '^EnvironmentFile=-%h/.config/pr-redteam/merge.env$' "$unit"
if grep -Eq '^Environment=.*REDTEAM_MERGE_TOKEN_FILE' "$unit"; then echo 'forbidden credential or activation evidence' >&2; exit 1; fi
if grep -E 'credentials/|\.pat' "$unit" | grep -qv '^Environment=JERYU_TOKEN_FILE='; then echo 'forbidden credential or activation evidence' >&2; exit 1; fi
[[ "$(find "$t/home/.config/systemd/user" -type f | wc -l)" == 6 ]]
# The poke unit runs this directory's script, like the review and heartbeat units.
grep -q "^ExecStart=$here/pr-redteam poke\$" "$t/home/.config/systemd/user/pr-redteam-poke.service"
if grep -Eq 'enable --now|start --no-block|disable|stop ' "$t/calls"; then echo 'forbidden credential or activation evidence' >&2; exit 1; fi
sha256sum "$t/home/.config/systemd/user/"* > "$t/before"
if run 1; then echo 'active installation was accepted' >&2; exit 1; fi
sha256sum -c "$t/before" > /dev/null
if grep -Eq 'enable --now|start --no-block|disable|stop ' "$t/calls"; then echo 'forbidden credential or activation evidence' >&2; exit 1; fi
echo 'INACTIVE INSTALLATION PASS'
