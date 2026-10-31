#!/usr/bin/env bash
# Exercise pr-gate-cargo-plugin-install.sh: a plugin lands in ~/.cargo/bin only inside the drain,
# as a copy, and only for a plain cargo-* name.
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_|CARGO_HOME)' || true)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
fx=$(mktemp -d)
trap 'rm -rf -- "$fx"' EXIT
mkdir -p "$fx/stub" "$fx/home/gate-runner/bin" "$fx/home/.cargo/bin"
printf 'PR_GATE_CODE_REPO=example/gate-code\n' >"$fx/pr-gate.env"
cat >"$fx/stub/systemctl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$fx/calls.log"
if [[ "\$*" == *list-units* ]]; then printf 'pr-gate-runner@0.timer loaded active waiting x\n'; fi
exit 0
SH
cat >"$fx/stub/pgrep" <<SH
#!/usr/bin/env bash
[[ -e "$fx/busy" ]]
SH
chmod +x "$fx/stub/systemctl" "$fx/stub/pgrep"
printf '#!/bin/sh\necho v1\n' >"$fx/real-plugin"; chmod +x "$fx/real-plugin"
ln -s "$fx/real-plugin" "$fx/link-plugin"
printf 'data\n' >"$fx/plain"; chmod -x "$fx/plain"
dest="$fx/home/.cargo/bin"
run() { : >"$fx/calls.log"; status=0
  HOME="$fx/home" PATH="$fx/stub:$PATH" PR_GATE_CONFIG="$fx/pr-gate.env" GATE_INSTALL_DRAIN_SECONDS="${drain:-5}" \
    bash "$script_dir/pr-gate-cargo-plugin-install.sh" "$@" >"$fx/out" 2>&1 || status=$?; }
must() { local why=$1; shift; "$@" || { printf 'FAIL: %s\n' "$why" >&2; cat "$fx/out" "$fx/calls.log" >&2; exit 1; }; }

for bad in ../cargo-x cargo-.. not-cargo cargo- 'cargo-x/y' '-cargo-x'; do
  run "$bad" "$fx/real-plugin"
  must "bad name accepted: $bad" test "$status" == 2
  must "bad name touched a timer: $bad" test ! -s "$fx/calls.log"
done
run cargo-x "$fx/plain"; must 'non-executable source accepted' test "$status" == 2
run cargo-x "$fx/missing"; must 'missing source accepted' test "$status" == 2
must 'rejected input installed something' test -z "$(ls -A "$dest")"
printf 'PASS only a bare cargo-* name and an executable source are accepted\n'

run cargo-x "$fx/link-plugin"
must 'install failed' test "$status" == 0
must 'plugin not installed' test -x "$dest/cargo-x"
must 'plugin is a link, not a copy' test ! -L "$dest/cargo-x"
must 'plugin bytes differ' cmp -s "$fx/real-plugin" "$dest/cargo-x"
must 'slot not paused' grep -q -- '--user stop pr-gate-runner@0.timer' "$fx/calls.log"
must 'slot not resumed' grep -q -- '--user start pr-gate-runner@0.timer' "$fx/calls.log"
printf '#!/bin/sh\necho v2\n' >"$fx/real-plugin"
must 'installed copy followed a later source rewrite' grep -q v1 "$dest/cargo-x"
printf 'PASS the plugin is copied inside the drain and later source rewrites do not reach it\n'

touch "$fx/busy"; rm -f "$dest/cargo-x"
drain=0 run cargo-x "$fx/real-plugin"
must 'a busy host was installed into' test "$status" == 75
must 'plugin appeared on a busy host' test ! -e "$dest/cargo-x"
rm -f "$fx/busy"
printf 'PASS a host that does not drain installs nothing\n'
printf 'pr-gate-cargo-plugin-install: all checks passed\n'
