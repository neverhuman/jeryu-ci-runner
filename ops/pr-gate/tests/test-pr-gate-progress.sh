#!/usr/bin/env bash
# Exercise pr-gate-progress.sh: step lines from real recipe output shapes, first-seen times, the
# checklist while running / green / red, the learned "usually" list, and the posted check run.
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/pr-gate-progress.sh"
fx=$(mktemp -d)
trap 'rm -rf -- "$fx"' EXIT
HOME_DIR="$fx/home"
# shellcheck source=ops/pr-gate/bin/pr-gate-progress.sh
source "$lib"
must() { local why=$1; shift; "$@" || { printf 'FAIL: %s\n' "$why" >&2; exit 1; }; }
same() { [[ "$1" == "$2" ]] || { printf 'FAIL: %s\n--- want\n%s\n--- got\n%s\n' "$3" "$2" "$1" >&2; exit 1; }; }

cat >"$fx/build.log" <<'LOG'
[pr-ci] tracked-but-ignored files
no tracked files are gitignored
[pr-ci] (jobs=8) cargo fmt --all --check
[ci] required lane: cargo clippy
==> playwright
> typecheck
> tsc -b --pretty false
> test:contracts
> tsd
[pr-ci] (jobs=8) cargo fmt --all --check
[pr-ci] jeryu-web OK
[pr-ci] PASS — fmt + clippy all green
LOG
same "$(gate_step_markers "$fx/build.log")" "tracked-but-ignored files
cargo fmt --all --check
cargo clippy
playwright
npm typecheck
npm test:contracts
cargo fmt --all --check" 'step lines: [pr-ci], [ci] lanes, ==>, npm script names (not their commands), no OK/PASS banners'
printf 'PASS step lines come from every recipe shape, npm names its scripts once\n'

: >"$fx/steps.tsv"
printf '[pr-ci] one\n' >"$fx/live.log"
must 'a new step is recorded' gate_steps_record "$fx/live.log" "$fx/steps.tsv" 100
must 'nothing new is not a change' bash -c "! { source '$lib'; gate_steps_record '$fx/live.log' '$fx/steps.tsv' 105; }"
printf '[pr-ci] two\n' >>"$fx/live.log"
must 'the next step is recorded at its own time' gate_steps_record "$fx/live.log" "$fx/steps.tsv" 130
same "$(cat "$fx/steps.tsv")" $'100\tone\n130\ttwo' 'each step keeps the time it first appeared'
printf 'PASS each step is recorded once, at the time it first appeared\n'

printf 'one\t25\ntwo\t60\nthree\t200\n' >"$fx/planned.tsv"
same "$(gate_progress_summary "$fx/steps.tsv" "$fx/planned.tsv" running 145)" "✓ one · 30s
▸ two · 15s so far
○ three · usually 3m20s
2 of 3 steps · 45s so far · usually 4m45s" 'running: done, current, still to come with their usual time'
same "$(gate_progress_summary "$fx/steps.tsv" "" success 230)" "✓ one · 30s
✓ two · 1m40s
2 steps · 2m10s" 'green: every step done, with its time'
same "$(gate_progress_summary "$fx/steps.tsv" "" failure 140 'clippy refused')" "✓ one · 30s
✗ two · 10s — clippy refused
2 steps · 40s" 'red: the last step is the one that failed, with the cause'
same "$(gate_progress_summary "$fx/missing.tsv" "" failure 140)" "The recipe printed no step lines." 'a recipe without step lines says so'
printf 'PASS the checklist reads running, green and red, and names what is still to come\n'

gate_steps_learn "$fx/steps.tsv" 230 "$(gate_planned_path acme app)"
same "$(cat "$HOME_DIR/cache/steps-acme__app.tsv")" $'one\t30\ntwo\t100' 'a green attempt becomes the repo plan'
same "$(gate_fmt_secs 3725)" "1h02m" 'hours'
printf 'PASS a green attempt teaches the next one its steps and times\n'

posted=""
api() { posted="$1 $2 $3"; code=201; body='{}'; }
gate_progress_check_run acme app abc in_progress "" "Gate running: two" "▸ two" "https://forge/repos/x/acme/app/pulls/7/checks"
must 'posted to check-runs' grep -q '^POST /repos/acme/app/check-runs ' <<<"$posted"
payload=${posted#POST /repos/acme/app/check-runs }
must 'in progress, no conclusion, the checklist as the summary, the PR checks page as the link' \
  jq -e '.name == "pr-gate-runner" and .status == "in_progress" and (has("conclusion") | not)
    and .output.summary == "▸ two" and .details_url == "https://forge/repos/x/acme/app/pulls/7/checks"' <<<"$payload" >/dev/null
printf 'PASS the progress check run carries the checklist and links the PR checks page\n'

report="$(dirname "$lib")/pr-gate-steps-report.sh"
mk() { local d="$fx/runner/attempts/k$1/a$1"; mkdir -p "$d"
  printf '{"owner":"acme","repo":"web","outcome":"%s"}\n' "$2" >"$d/receipt.json"; printf "$3" >"$d/steps.tsv"; echo "$4" >"$d/steps.end"; }
mk 1 success '0\tlint\n10\te2e\n200\tbuild\n' 260
mk 2 success '0\tlint\n14\te2e\n220\tbuild\n' 270
mk 3 failure '0\tlint\n5\te2e\n' 50
out=$(GATE_RUNNER_HOME="$fx/runner" bash "$report")
must 'the report names the repo and counts green attempts only' grep -q '^acme/web · 2 attempts$' <<<"$out"
same "$(awk 'NR > 2 && NF { print $1 }' <<<"$out" | head -3 | tr '\n' ' ')" "e2e build lint " 'slowest step first, by median'
must 'the slow step shows its median, p90, max, share and runs' grep -qE '^e2e +3m10s +3m26s +3m26s +76% +2$' <<<"$out"
must '--all counts the red attempt too' grep -q '^acme/web · 3 attempts$' <<<"$(GATE_RUNNER_HOME="$fx/runner" bash "$report" --all)"
printf 'PASS the report ranks each repo steps by median time, with p90, max, share and runs\n'
