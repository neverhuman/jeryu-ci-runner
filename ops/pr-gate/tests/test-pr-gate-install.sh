#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs and fixture tool bodies, not shell
# Exercise pr-gate-install.sh against a fixture source repository (the gate component under
# ops/pr-gate/, as in this repository), with systemctl and pgrep stubs that record calls.
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
installer="$script_dir/pr-gate-install.sh"
fx=$(mktemp -d)
trap 'rm -rf -- "$fx"' EXIT

git init -q --initial-branch=main "$fx/src"
git -C "$fx/src" config user.name Fixture; git -C "$fx/src" config user.email fixture@example.invalid
c=ops/pr-gate
mkdir -p "$fx/src/$c/bin" "$fx/src/$c/systemd" "$fx/src/other"
put() { printf '%s\n' "$2" >"$fx/src/$1"; git -C "$fx/src" add "$1"; }
commit() { git -C "$fx/src" commit -qm "$1"; }
put $c/bin/pr-gate-runner.sh '#!/usr/bin/env bash
echo runner v1'
put $c/bin/pr-gate-state.sh 'state() { :; }'
put $c/bin/pr-gate-config.sh 'pr_gate_load_config() { :; }'
put $c/bin/notes.txt 'not a managed file'
put $c/systemd/pr-gate-runner@.timer '[Timer]'
put $c/VERSION '1.0.0'
put other/pr-gate-runner.sh 'echo outside the component'
commit v1
git -C "$fx/src" tag release-v1
# Site configuration: where the component comes from. Read as KEY=VALUE lines.
printf 'PR_GATE_SOURCE_URL=%s\nPR_GATE_SOURCE_SUBDIR="ops/pr-gate/"\nPR_GATE_CODE_REPO=example/gate-code\n' "$fx/src" >"$fx/pr-gate.env"
mirror="$fx/home/gate-runner/source/pr-gate.git"

mkdir -p "$fx/stub" "$fx/home/gate-runner/bin" "$fx/home/.config/systemd/user"
cat >"$fx/stub/systemctl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$fx/systemctl.log"
if [[ "\$*" == *list-units* ]]; then printf 'pr-gate-runner@0.timer loaded active waiting x\npr-gate-runner@1.timer loaded active waiting x\n'; fi
exit 0
SH
cat >"$fx/stub/pgrep" <<SH
#!/usr/bin/env bash
[[ -e "$fx/busy" ]]
SH
chmod +x "$fx/stub/systemctl" "$fx/stub/pgrep"
# The gate's governed tools: one with --version, one with only a `version` subcommand, one with
# neither, a non-executable file, and a name outside the forge's alphabet; plus a governed jankurai.
mkdir -p "$fx/tools" "$fx/governed"
tool() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$1"; chmod +x "$1"; }
tool "$fx/tools/jankurai" '[[ "$1" == --version ]] && { echo; echo "jankurai 1.6.11"; echo extra; exit 0; }; exit 2'
tool "$fx/tools/gitleaks" '[[ "$1" == version ]] && { echo v8.18.4; exit 0; }; exit 1'
tool "$fx/tools/silent" 'exit 3'
tool "$fx/tools/bad name" 'echo 1'
printf 'not a tool\n' >"$fx/tools/README"
tool "$fx/governed/jankurai" '[[ "$1" == --version ]] && echo "jankurai 1.6.10"'
run() { : >"$fx/systemctl.log"; HOME="$fx/home" PATH="$fx/stub:$PATH" GATE_INSTALL_DRAIN_SECONDS="${drain:-30}" \
  GATE_RUNNER_TOOLS="$fx/tools" PR_GATE_GOVERNED_JANKURAI="$fx/governed/jankurai" PR_GATE_CONFIG="$fx/pr-gate.env" \
  bash "$installer"; }
bin="$fx/home/gate-runner/bin"
# Every assertion fails loudly: a grep inside an && list is not covered by set -e.
must() { local why=$1; shift; "$@" || { printf 'FAIL: %s\n' "$why" >&2; cat "$fx/out" "$fx/systemctl.log" >&2 2>/dev/null; exit 1; }; }
called() { grep -qx -- "--user $1" "$fx/systemctl.log"; }

# Without a configured source nothing is fetched or installed, and it says which setting is missing.
if HOME="$fx/home" PATH="$fx/stub:$PATH" PR_GATE_CONFIG="$fx/none.env" GATE_RUNNER_TOOLS="$fx/tools" \
  bash "$installer" >"$fx/out" 2>&1; then printf 'FAIL: an unconfigured source was accepted\n' >&2; exit 1; fi
must 'missing source named' grep -q 'PR_GATE_SOURCE_URL is not configured' "$fx/out"
must 'nothing installed unconfigured' test ! -e "$bin/pr-gate-runner.sh"
printf 'PASS no configured source: refused by name, nothing installed\n'

run >"$fx/out"
must 'runner v1 installed' grep -q 'echo runner v1' "$bin/pr-gate-runner.sh"
must 'runner executable' test -x "$bin/pr-gate-runner.sh"
must 'config library installed' test -x "$bin/pr-gate-config.sh"
must 'only bin/pr-gate-*.sh is managed' test ! -e "$bin/notes.txt"
must 'nothing from outside the component' grep -q 'echo runner v1' "$bin/pr-gate-runner.sh"
must 'units come from the component' test -e "$fx/home/.config/systemd/user/pr-gate-runner@.timer"
must 'slot 0 stopped for the drain' called 'stop pr-gate-runner@0.timer'
must 'slot 1 resumed' called 'start pr-gate-runner@1.timer'
must 'units reloaded' called 'daemon-reload'
v1=$(git -C "$fx/src" rev-parse main)
must 'commit recorded' test "$(jq -r .commit "$fx/home/gate-runner/installed-main.json")" == "$v1"
printf 'PASS first install: files from main, slots drained and resumed, units reloaded, commit recorded\n'
# Heartbeats report this record as the runner's code (gate_runner_code in the real state library).
code_json=$(PR_GATE_CODE_REPO=example/gate-code bash -c 'source "$1"; gate_runner_code "$2"' _ "$script_dir/pr-gate-state.sh" "$fx/home/gate-runner")
# shellcheck disable=SC2016 # a jq program, not shell
must 'heartbeat code is the installed commit' jq -e --arg c "$v1" \
  '.repo=="example/gate-code" and .commit==$c and (.installedAt|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' <<<"$code_json" >/dev/null
printf 'PASS the install record is what heartbeats report as the runner code\n'
state="$fx/home/gate-runner/installed-main.json"
must 'version is the component VERSION' jq -e '.version=="pr-gate 1.0.0"' "$state" >/dev/null
must 'code.version is passed on' jq -e '.version=="pr-gate 1.0.0"' <<<"$code_json" >/dev/null
must 'no tags fetched' test -z "$(git -C "$mirror" tag -l)"
must 'mirror tracks the configured source' test "$(git -C "$mirror" remote get-url origin)" == "$fx/src"
printf 'PASS the version is `pr-gate <VERSION>`, and heartbeats pass it on\n'

tools="$fx/home/gate-runner/tools.json"
sha() { sha256sum "$1" | cut -d' ' -f1; }
# shellcheck disable=SC2016 # a jq program, not shell
must 'tools.json lists the governed tools' jq -e --arg j "$(sha "$fx/tools/jankurai")" --arg g "$(sha "$fx/tools/gitleaks")" \
  --arg s "$(sha "$fx/tools/silent")" --arg gj "$(sha "$fx/governed/jankurai")" '
  (.generated_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
  and .tools == [{name:"gitleaks",version:"v8.18.4",sha256:$g},
                 {name:"jankurai",version:"1.6.11",sha256:$j},
                 {name:"jankurai@governed",version:"1.6.10",sha256:$gj},
                 {name:"silent",sha256:$s}]' "$tools" >/dev/null
tools_json=$(bash -c 'source "$1"; gate_runner_tools "$2"' _ "$script_dir/pr-gate-state.sh" "$fx/home/gate-runner")
must 'heartbeat tools are tools.json' jq -e --slurpfile f "$tools" '. == $f[0].tools' <<<"$tools_json" >/dev/null
printf 'PASS tools.json names each governed tool with version (--version, else version) and sha256, plus jankurai@governed\n'

run >"$fx/out"
[[ ! -s "$fx/systemctl.log" ]] || { printf 'a no-op run touched systemd:\n' >&2; cat "$fx/systemctl.log" >&2; exit 1; }
printf 'PASS nothing new on main: no drain, no install\n'

# Hosts installed before this change carry an older version form (`main <date>`, or a `git describe`);
# the next verify pass rewrites it to the current form and keeps the record otherwise, and refreshes
# tools.json.
installed_at=$(jq -r .installed_at "$state")
jq '.version="main 2026-10-01"' "$state" >"$state.tmp" && mv "$state.tmp" "$state"
tool "$fx/tools/jankurai" '[[ "$1" == --version ]] && echo "jankurai 1.6.12"'
rm -f "$fx/governed/jankurai"
run >"$fx/out"
[[ ! -s "$fx/systemctl.log" ]] || { printf 'a version rewrite touched systemd:\n' >&2; cat "$fx/systemctl.log" >&2; exit 1; }
# shellcheck disable=SC2016 # a jq program, not shell
must 'stale version rewritten on verify' jq -e --arg c "$v1" --arg at "$installed_at" --arg v "pr-gate 1.0.0" \
  '.version==$v and .commit==$c and .installed_at==$at' "$state" >/dev/null
must 'tools.json refreshed on verify' jq -e '[.tools[]|select(.name=="jankurai")|.version]==["1.6.12"]
  and ([.tools[].name]|index("jankurai@governed")==null)' "$tools" >/dev/null
printf 'PASS a stale version form is rewritten on the next verify pass; tools.json is refreshed every run\n'

put $c/bin/pr-gate-runner.sh '#!/usr/bin/env bash
echo runner v2'
put $c/VERSION '1.0.1'
commit v2
v2=$(git -C "$fx/src" rev-parse --short=7 main)
run >"$fx/out"
must 'runner v2 installed' grep -q 'echo runner v2' "$bin/pr-gate-runner.sh"
must 'predecessor kept' test -n "$(compgen -G "$bin/pr-gate-runner.sh.*-pre-$v2.bak")"
must 'slots drained for a runner change' called 'stop pr-gate-runner@0.timer'
if called 'daemon-reload'; then printf 'FAIL: reloaded systemd without a unit change\n' >&2; exit 1; fi
must 'install records the new VERSION' jq -e '.version=="pr-gate 1.0.1"' "$state" >/dev/null
printf 'PASS runner change: drained, installed with its predecessor kept, no reload, version recorded\n'

put $c/bin/pr-gate-runner.sh 'echo "unterminated'
commit broken
if run >"$fx/out" 2>&1; then printf 'FAIL: an unparsable runner was accepted\n' >&2; exit 1; fi
must 'runner v2 kept' grep -q 'echo runner v2' "$bin/pr-gate-runner.sh"
if called 'stop pr-gate-runner@0.timer'; then printf 'FAIL: drained for a runner that does not parse\n' >&2; exit 1; fi
printf 'PASS a runner that does not parse is never installed\n'

put $c/bin/pr-gate-runner.sh '#!/usr/bin/env bash
echo runner v3'
commit v3
touch "$fx/busy"
drain=1 run >"$fx/out" 2>&1
must 'nothing installed while a gate runs' grep -q 'echo runner v2' "$bin/pr-gate-runner.sh"
must 'slot 0 resumed after a failed drain' called 'start pr-gate-runner@0.timer'
must 'slot 1 resumed after a failed drain' called 'start pr-gate-runner@1.timer'
rm -f "$fx/busy"
run >"$fx/out"
must 'runner v3 installed once idle' grep -q 'echo runner v3' "$bin/pr-gate-runner.sh"
printf 'PASS a busy slot defers the install to the next interval, and slots are resumed\n'

put $c/systemd/pr-gate-install.timer '[Timer]'
commit timer
run >"$fx/out"
must 'units reloaded' called 'daemon-reload'
must 'managed timer enabled' called 'enable --now pr-gate-install.timer'
if called 'stop pr-gate-runner@0.timer'; then printf 'FAIL: drained for a unit-only change\n' >&2; exit 1; fi
printf 'PASS a unit change reloads systemd and enables managed timers without draining\n'

# A change to the config library drains like the runner: it decides what the runner gates.
put $c/bin/pr-gate-config.sh 'pr_gate_load_config() { return 0; }'
commit config
run >"$fx/out"
must 'config library change drains' called 'stop pr-gate-runner@0.timer'
must 'config library installed' grep -q 'return 0' "$bin/pr-gate-config.sh"
printf 'PASS a config library change drains the slots before installing\n'

# A malformed VERSION records no version rather than a wrong one; the install itself proceeds.
put $c/VERSION 'one point oh'
put $c/bin/pr-gate-wake.sh '#!/usr/bin/env bash'
commit bad-version
run >"$fx/out"
must 'new script installed' test -x "$bin/pr-gate-wake.sh"
must 'malformed VERSION is not recorded' jq -e 'has("version")|not' "$state" >/dev/null
printf 'PASS a malformed VERSION records no version\n'

# Another source branch, by configuration alone: the mirror follows it.
git -C "$fx/src" checkout -q -b gate-stable
put $c/bin/pr-gate-heartbeat.sh '#!/usr/bin/env bash
echo stable heartbeat'
put $c/VERSION '1.1.0'
commit stable
git -C "$fx/src" checkout -q main
printf 'PR_GATE_SOURCE_URL=%s\nPR_GATE_SOURCE_BRANCH=gate-stable\n' "$fx/src" >"$fx/pr-gate.env"
run >"$fx/out"
must 'branch installed' grep -q 'stable heartbeat' "$bin/pr-gate-heartbeat.sh"
must 'branch commit recorded' test "$(jq -r .commit "$state")" == "$(git -C "$fx/src" rev-parse gate-stable)"
must 'branch version recorded' jq -e '.version=="pr-gate 1.1.0"' "$state" >/dev/null
printf 'PASS PR_GATE_SOURCE_BRANCH selects the branch the installer follows\n'
