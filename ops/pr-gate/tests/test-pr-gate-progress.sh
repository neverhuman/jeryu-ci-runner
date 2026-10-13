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
> jeryu-web@0.1.0 typecheck
> tsc -b --pretty false
> @acme/web@1.2.3-rc.1 test:contracts /srv/tree/web
> tsd
> quoted tool output, not a banner
> another quoted line
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
cargo fmt --all --check" 'step lines: [pr-ci], [ci] lanes, ==>, npm run banners only (not commands or quoted "> " lines), no OK/PASS banners'
printf '==> a\ttabbed\001step\r\n' >"$fx/ctl.log"
same "$(gate_step_markers "$fx/ctl.log")" "a tabbed step" 'tabs, control characters and CR become spaces: a step is one TSV field'
printf 'PASS step lines come from every recipe shape; npm names a step only by its real run banner\n'

# A line still being written is not a step yet; once it ends, it is recorded whole, once.
: >"$fx/partial.tsv"
printf '[pr-ci] one\n[pr-ci] car' >"$fx/partial.log"
gate_steps_record "$fx/partial.log" "$fx/partial.tsv" 10 || true
printf 'go fmt\n' >>"$fx/partial.log"
gate_steps_record "$fx/partial.log" "$fx/partial.tsv" 12 || true
same "$(cat "$fx/partial.tsv")" $'10\tone\n12\tcargo fmt' 'a partial line is read only once it is complete'
printf 'PASS only complete log lines are recorded\n'

: >"$fx/steps.tsv"
printf '[pr-ci] one\n' >"$fx/live.log"
must 'a new step is recorded' gate_steps_record "$fx/live.log" "$fx/steps.tsv" 100
must 'nothing new is not a change' bash -c "! { source '$lib'; gate_steps_record '$fx/live.log' '$fx/steps.tsv' 105; }"
printf '[pr-ci] two\n' >>"$fx/live.log"
must 'the next step is recorded at its own time' gate_steps_record "$fx/live.log" "$fx/steps.tsv" 130
same "$(cat "$fx/steps.tsv")" $'100\tone\n130\ttwo' 'each step keeps the time it first appeared'
printf 'PASS each step is recorded once, at the time it first appeared\n'

printf 'one\t25\ntwo\t60\nthree\t200\n' >"$fx/planned.tsv"
printf 'echo "[pr-ci] one"; echo "[pr-ci] two"; echo "[pr-ci] three"\n' >"$fx/vocab"
same "$(gate_progress_summary "$fx/steps.tsv" "$fx/planned.tsv" "$fx/vocab" running 145)" "✓ one · 30s
▸ two · 15s so far
○ three · usually 3m20s
2 of 3 steps · 45s so far · usually 4m45s" 'running: done, current, still to come with their usual time'
same "$(gate_progress_summary "$fx/steps.tsv" "" "$fx/vocab" success 230)" "✓ one · 30s
✓ two · 1m40s
2 steps · 2m10s" 'green: every step done, with its time'
same "$(gate_progress_summary "$fx/steps.tsv" "" "$fx/vocab" failure 140 'clippy refused')" "✓ one · 30s
✗ two · 10s — clippy refused
2 steps · 40s" 'red: the last step is the one that failed, with the cause'
same "$(gate_progress_summary "$fx/missing.tsv" "" "$fx/vocab" failure 140)" "The recipe printed no step lines." 'a recipe without step lines says so'
printf 'PASS the checklist reads running, green and red, and names what is still to come\n'

gate_steps_learn "$fx/steps.tsv" 230 "$(gate_planned_path acme app)"
same "$(cat "$HOME_DIR/cache/steps-acme__app.tsv")" $'one\t30\ntwo\t100' 'a green attempt becomes the repo plan'
same "$(gate_fmt_secs 3725)" "1h02m" 'hours'
gate_steps_learn "$fx/steps.tsv" "" "$fx/no-end.tsv"
must 'an attempt without its recorded end teaches nothing' test ! -e "$fx/no-end.tsv"
# A damaged plan (a name with a tab in it, from before names were cleaned) must not stop the watcher.
printf 'one\tbroken\tfield\ntwo\tx\n' >"$fx/damaged.tsv"
same "$(set -u; gate_progress_summary "$fx/steps.tsv" "$fx/damaged.tsv" "$fx/vocab" running 145 | tail -1)" \
  "2 of 2+ steps · 45s so far" 'non-numeric planned seconds read as 0 and never abort'
same "$(set -u; gate_fmt_secs 'x y')" "0s" 'a non-number formats as 0s'
printf 'PASS a green attempt teaches the next one its steps and times; a damaged plan is harmless\n'

posted=""
api() { posted="$1 $2 $3"; code=201; }
gate_progress_check_run acme app abc in_progress "" "Gate running: two" "▸ two" "https://forge/repos/x/acme/app/pulls/7/checks"
must 'posted to check-runs' grep -q '^POST /repos/acme/app/check-runs ' <<<"$posted"
payload=${posted#POST /repos/acme/app/check-runs }
must 'in progress, no conclusion, the checklist as the summary, the PR checks page as the link' \
  jq -e '.name == "pr-gate-runner" and .status == "in_progress" and (has("conclusion") | not)
    and .output.summary == "▸ two" and .details_url == "https://forge/repos/x/acme/app/pulls/7/checks"' <<<"$payload" >/dev/null
printf 'PASS the progress check run carries the checklist and links the PR checks page\n'

# A forge that refuses the link (422) still gets the progress, without it.
posts=()
api() { posts+=("$3"); if jq -e 'has("details_url")' <<<"$3" >/dev/null; then code=422; else code=201; fi; }
gate_progress_check_run acme app abc in_progress "" "t" "s" "https://forge/repos/x/acme/app/pulls/7/checks"
must 'retried once without the link' test "${#posts[@]}" -eq 2
must 'the retry has no link' jq -e 'has("details_url") | not' <<<"${posts[1]}" >/dev/null
printf 'PASS a refused link is dropped, never the progress post\n'

# The checks URL is derived from the forge's answer for exactly the PR being gated.
same "$(gate_checks_url acme app 7 '{"html_url":"https://forge.invalid/repos/jeryu/acme/app/pulls/7"}')" \
  "https://forge.invalid/repos/jeryu/acme/app/pulls/7/checks" 'the PR page plus /checks'
same "$(gate_checks_url acme app 7 '{"html_url":"https://forge.invalid/repos/jeryu/acme/app/pulls/8"}')" "" 'another PR links nothing'
same "$(gate_checks_url acme app 7 '{"html_url":"https://forge.invalid/repos/jeryu/acme/other/pulls/7"}')" "" 'another repo links nothing'
same "$(gate_checks_url acme app 7 '{"html_url":"javascript:alert(1)//acme/app/pulls/7"}')" "" 'a non-https URL links nothing'
same "$(gate_checks_url acme app 7 '{}')" "" 'no html_url links nothing'
printf 'PASS the checks link names exactly the gated PR, or nothing\n'

# What is published is never the log. The head's recipe runs as the gate user, so it can print
# anything; a step is named only by text protected main's gate sources contain, within a charset and
# length, and at most GATE_STEPS_SHOWN of them. Everything else is "step N".
repo_fx="$fx/repo"
git init -q --initial-branch=main "$repo_fx"
git -C "$repo_fx" config user.name Fixture; git -C "$repo_fx" config user.email fixture@example.invalid
mkdir -p "$repo_fx/ops/ci" "$repo_fx/web" "$repo_fx/docs"
# shellcheck disable=SC2016  # the recipe's own text, written as-is
printf '#!/bin/sh\necho "[pr-ci] (jobs=$JOBS) cargo fmt --all --check" >&2\necho "[pr-ci] jankurai audit (>= 85)" >&2\n' >"$repo_fx/ops/ci/pr-ci.sh"
printf '{"scripts":{"typecheck":"tsc -b"}}\n' >"$repo_fx/web/package.json"
printf 'docs are not gate sources: docs only step\n' >"$repo_fx/docs/x.md"
git -C "$repo_fx" add . && git -C "$repo_fx" commit -qm main
git -C "$repo_fx" checkout -q -b head
# Built at run time, so no token-shaped literal sits in the repository text.
secret="gh""p_ABCDEFGHIJKLMNOPQRSTUV0123"
printf 'echo "==> %s"\necho "[pr-ci] head only step"\n' "$secret" >>"$repo_fx/ops/ci/pr-ci.sh"
git -C "$repo_fx" commit -qam head
gate_step_vocabulary "$repo_fx" main "$fx/main-vocab"
cat >"$fx/head.log" <<LOG
[pr-ci] (jobs=4) cargo fmt --all --check
==> $secret
[pr-ci] head only step
[pr-ci] docs only step
> web@0.1.0 typecheck
[pr-ci] jankurai audit (>= 85)
==> cargo fmt --all --check; \$(id)
LOG
: >"$fx/head.tsv"
gate_steps_record "$fx/head.log" "$fx/head.tsv" 100 || true
must 'the real text stays in steps.tsv on the runner' grep -qF "$secret" "$fx/head.tsv"
same "$(gate_progress_summary "$fx/head.tsv" "" "$fx/main-vocab" success 160)" "✓ cargo fmt --all --check · 0s
✓ step 2 · 0s
✓ step 3 · 0s
✓ step 4 · 0s
✓ npm typecheck · 0s
✓ jankurai audit (>= 85) · 0s
✓ step 7 · 1m00s
7 steps · 1m00s" 'main-sourced names are published; the head'"'"'s own text, docs and shell syntax are "step N"'
same "$(gate_progress_current "$fx/head.tsv" "$fx/main-vocab")" "step 7" 'the running step in the title follows the same rule'
same "$(gate_progress_summary "$fx/head.tsv" "" "$fx/none" success 160 | head -1)" "✓ step 1 · 0s" 'without main sources nothing is named'
long=$(printf 'x%.0s' {1..120})
printf 'echo "==> %s"\n' "$long" >"$fx/long-vocab"
same "$(gate_step_public "$fx/long-vocab" 1 "$long")" "${long:0:80}" 'a name is cut to 80 characters'
: >"$fx/many.tsv"
for i in $(seq 1 75); do printf '%d\tone\n' "$i" >>"$fx/many.tsv"; done
out=$(gate_progress_summary "$fx/many.tsv" "$fx/planned.tsv" "$fx/vocab" running 80)
must 'at most 60 steps are listed' test "$(grep -c '^[✓▸○] ' <<<"$out")" -eq 60
must 'the rest are counted' grep -qx '… 15 earlier steps' <<<"$out"
printf 'PASS only protected main'"'"'s own step names are published, bounded in charset, length and count\n'

# The live watcher: while a forge back-off runs it posts nothing, its posts never clear the back-off,
# and a burst of steps is one post per GATE_PROGRESS_MIN_GAP.
# shellcheck source=ops/pr-gate/bin/pr-gate-backoff.sh
source "$(dirname "$lib")/pr-gate-backoff.sh"
api() { printf '%s\n' "${GATE_API_PASSIVE:-active}" >>"$fx/watch-posts"; code=201; }
watch() { # seconds
  : >"$fx/w.log"; : >"$fx/w.tsv"; rm -f "$fx/watch-posts"
  ( for i in $(seq 1 "$1"); do printf '[pr-ci] one\n[pr-ci] step %d\n' "$i" >>"$fx/w.log"; sleep 1; done ) &
  local worker=$!
  ( gate_progress_watch "$fx/w.log" "$fx/w.tsv" "$worker" acme app abc "" "$fx/vocab" "" ) &
  wait "$worker"; wait $! || true
}
mkdir -p "$HOME_DIR/cache"
printf '%s 1\n' "$(($(date +%s) + 300))" >"$BACKOFF_FILE"
watch 3
must 'nothing is posted during a back-off' test ! -e "$fx/watch-posts"
must 'the back-off is untouched' test "$(backoff_remaining)" -gt 0
backoff_clear
watch 4
must 'one post for a burst of steps' test "$(wc -l <"$fx/watch-posts")" -eq 1
must 'posted passively (never clears a back-off)' grep -qx 1 "$fx/watch-posts"
printf 'PASS live posts stand back during a forge back-off, never clear it, and are throttled\n'

report="$(dirname "$lib")/pr-gate-steps-report.sh"
mk() { local d="$fx/runner/attempts/k$1/a$1"; mkdir -p "$d"
  printf '{"owner":"acme","repo":"web","outcome":"%s"}\n' "$2" >"$d/receipt.json"; printf '%b' "$3" >"$d/steps.tsv"; echo "$4" >"$d/steps.end"; }
mk 1 success '0\tlint\n10\te2e\n200\tbuild\n' 260
mk 2 success '0\tlint\n14\te2e\n220\tbuild\n' 270
mk 3 failure '0\tlint\n5\te2e\n' 50
out=$(GATE_RUNNER_HOME="$fx/runner" bash "$report")
must 'the report names the repo and counts green attempts only' grep -q '^acme/web · 2 attempts$' <<<"$out"
same "$(awk 'NR > 2 && NF { print $1 }' <<<"$out" | head -3 | tr '\n' ' ')" "e2e build lint " 'slowest step first, by median'
must 'the slow step shows its median, p90, max, share and runs' grep -qE '^e2e +3m10s +3m26s +3m26s +76% +2$' <<<"$out"
must '--all counts the red attempt too' grep -q '^acme/web · 3 attempts$' <<<"$(GATE_RUNNER_HOME="$fx/runner" bash "$report" --all)"
printf 'PASS the report ranks each repo steps by median time, with p90, max, share and runs\n'

same "$(printf '%s\n' 'test temp directories on /dev/shm/jeryu-pr-ci.MIIRKT' 'jankurai score=88 caps=[]' \
  'receipt=/x/0123456789abcdef0123.json bin=/tmp/t.1fd5to/bin/j' 'jankurai audit (>= 85)' 'cargo fmt --all --check' | gate_step_keys)" \
  'test temp directories on <tmp>
jankurai score=<n> caps=[]
receipt=/x/<hex>.json bin=<tmp>
jankurai audit (>= 85)
cargo fmt --all --check' 'a step key replaces temp paths, digests and numbers after = with placeholders; nothing else'
printf '100\tsetup\n110\ttemp on /dev/shm/x.AAAA\n' >"$fx/vol.tsv"
printf 'setup\t10\ntemp on /dev/shm/x.BBBB\t90\nlint\t20\n' >"$fx/vol-planned.tsv"
same "$(gate_progress_summary "$fx/vol.tsv" "$fx/vol-planned.tsv" "$fx/vocab" running 130 | grep -c '^○')" 1 \
  'a step with a different temp path is the same step: only the step not yet seen is still to come'
mk 4 success '0\tlint\n10\ttemp on /dev/shm/x.AAAA\n200\tbuild\n' 260
mk 5 success '0\tlint\n14\ttemp on /dev/shm/x.BBBB\n220\tbuild\n' 270
out=$(GATE_RUNNER_HOME="$fx/runner" bash "$report")
must 'one row for a step whose temp path differs per run' grep -qE '^temp on <tmp> +3m10s +3m26s +3m26s +[0-9]+% +2$' <<<"$out"
printf 'PASS steps compare and group by key: a per-run temp path or digest is one step, not one per run\n'
