# shellcheck shell=bash
# pr-gate-progress.sh — what the gate is checking, step by step, and how long each step takes.
#
# A required status said only "ops/ci/pr-ci.sh running on pr-gate-runner@host" for eight minutes,
# with no page to open, so nobody could tell what was being checked, which step was slow or which
# one failed. The recipes already print a line as each step starts ("[pr-ci] cargo fmt --all
# --check", "[ci] required lane: cargo clippy", "==> ..."). While a gate runs, the runner reads
# those lines from the attempt's log, records when each first appeared (steps.tsv: epoch<TAB>step),
# and publishes the list as the `pr-gate-runner` check run's summary:
#
#   ✓ jankurai pin drift check          4s
#   ▸ cargo clippy                      1m12s so far
#   ○ cargo test                        usually 3m05s
#
# Times are when the line appeared, polled every couple of seconds: good to a few seconds, which
# is what deciding whether a long, low-value step should stay in the required gate needs. A green
# attempt's step times become the repo's "usually" list (cache/steps-<owner>__<repo>.tsv), which
# is also where the steps still to come are named. pr-gate-steps-report.sh summarises every
# attempt's steps.tsv per repo.
#
# Sourced by pr-gate-runner.sh. The posting helpers use its `api`; the rest is pure text.

# gate_step_markers LOG — the step lines of a recipe log, in order, one per line:
#   [pr-ci] <step>                       (jobs=N) prefixes dropped
#   [ci] required|fast lane: <step>
#   ==> <step>
#   > <npm script>                       npm's banner: "> name" then "> command"; the name is the step
# The closing "<repo> OK" / "PASS — ..." banners are not steps.
gate_step_markers() {
  [[ -f "$1" ]] || return 0
  LC_ALL=C awk '
    function emit(step) {
      if (step == "" || step ~ / OK$/ || step ~ /^PASS( |$)/ || step == previous) return
      print step; previous = step
    }
    /^\[pr-ci\] / { s = substr($0, 9); sub(/^\(jobs=[0-9]+\) /, "", s); emit(s); npm = 0; next }
    /^\[ci\] (required|fast) lane: / { s = $0; sub(/^\[ci\] (required|fast) lane: /, "", s); emit(s); npm = 0; next }
    /^==> / { emit(substr($0, 5)); npm = 0; next }
    /^> / { if (!npm) emit("npm " substr($0, 3)); npm = !npm; next }
    { npm = 0 }
  ' "$1"
}

# gate_steps_record LOG STEPS_TSV [NOW] — append the steps that appeared since the last call, each
# with NOW (default: the current time). True when anything was added.
gate_steps_record() {
  local now="${3:-$(date +%s)}" seen=0 i added=1
  local -a all=()
  [[ -f "$2" ]] && seen=$(grep -c . "$2" || true)
  mapfile -t all < <(gate_step_markers "$1")
  for ((i = seen; i < ${#all[@]}; i++)); do
    printf '%s\t%s\n' "$now" "${all[$i]}" >>"$2"
    added=0
  done
  return "$added"
}

# gate_fmt_secs SECONDS — 7s, 1m05s, 1h02m.
gate_fmt_secs() {
  local s=$1
  if ((s >= 3600)); then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif ((s >= 60)); then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"; fi
}

# gate_progress_summary STEPS_TSV PLANNED_TSV STATE END [CAUSE] — the checklist. STATE is running,
# success, or anything else (a failure: the last step is the one that failed). END is the epoch
# the attempt ended at (or now, while running). PLANNED_TSV ("step<TAB>seconds", from the repo's
# last green attempt) names the steps still to come and their usual times; it may be absent.
gate_progress_summary() {
  local steps=$1 planned=$2 state=$3 end=$4 cause=${5:-} i n started took mark tail total=0 usual=0
  local -a at=() name=() plan_name=() plan_secs=()
  local -A seen_name=()
  if [[ -f "$steps" ]]; then
    while IFS=$'\t' read -r t s; do [[ -n "$s" ]] && { at+=("$t"); name+=("$s"); seen_name[$s]=1; }; done <"$steps"
  fi
  if [[ -f "$planned" ]]; then
    while IFS=$'\t' read -r s t; do [[ -n "$s" ]] && { plan_name+=("$s"); plan_secs+=("${t:-0}"); usual=$((usual + ${t:-0})); }; done <"$planned"
  fi
  n=${#name[@]}
  for ((i = 0; i < n; i++)); do
    started=${at[$i]}
    if ((i + 1 < n)); then took=$((at[i + 1] - started)); else took=$((end - started)); fi
    ((took < 0)) && took=0
    if ((i + 1 < n)) || [[ "$state" == success ]]; then mark="✓" tail=$(gate_fmt_secs "$took")
    elif [[ "$state" == running ]]; then mark="▸" tail="$(gate_fmt_secs "$took") so far"
    else mark="✗" tail="$(gate_fmt_secs "$took")${cause:+ — $cause}"; fi
    printf '%s %s · %s\n' "$mark" "${name[$i]}" "$tail"
  done
  if [[ "$state" == running ]]; then
    for ((i = 0; i < ${#plan_name[@]}; i++)); do
      [[ -n "${seen_name[${plan_name[$i]}]:-}" ]] && continue
      printf '○ %s · usually %s\n' "${plan_name[$i]}" "$(gate_fmt_secs "${plan_secs[$i]}")"
    done
  fi
  ((n > 0)) && total=$((end - at[0]))
  if [[ "$state" == running ]]; then
    printf '%d of %s steps · %s so far%s\n' "$n" "$( ((${#plan_name[@]} > n)) && printf %d "${#plan_name[@]}" || printf '%d+' "$n")" \
      "$(gate_fmt_secs "$total")" "$( ((usual > 0)) && printf ' · usually %s' "$(gate_fmt_secs "$usual")")"
  elif ((n == 0)); then
    printf 'The recipe printed no step lines.\n'
  else
    printf '%d steps · %s\n' "$n" "$(gate_fmt_secs "$total")"
  fi
}

# gate_steps_learn STEPS_TSV END PLANNED_TSV — after a green attempt, its steps and times become
# the repo's planned list (the next attempt's "usually").
gate_steps_learn() {
  local steps=$1 end=$2 planned=$3 i n
  local -a at=() name=()
  [[ -s "$steps" ]] || return 0
  while IFS=$'\t' read -r t s; do [[ -n "$s" ]] && { at+=("$t"); name+=("$s"); }; done <"$steps"
  n=${#name[@]}
  mkdir -p -- "$(dirname -- "$planned")"
  {
    for ((i = 0; i < n; i++)); do
      if ((i + 1 < n)); then printf '%s\t%d\n' "${name[$i]}" $((at[i + 1] - at[i]))
      else printf '%s\t%d\n' "${name[$i]}" $((end - at[i])); fi
    done
  } >"$planned.tmp" && mv -f -- "$planned.tmp" "$planned"
}

# gate_planned_path OWNER REPO — where a repo's planned steps live.
gate_planned_path() { printf '%s/cache/steps-%s__%s.tsv\n' "$HOME_DIR" "$1" "$2"; }

# gate_progress_check_run OWNER REPO SHA STATUS CONCLUSION TITLE SUMMARY [DETAILS_URL] — post one
# `pr-gate-runner` check run. The forge keeps the newest run per name, so posting again replaces
# what the PR shows. Best effort: a refused progress post never affects the gate.
gate_progress_check_run() {
  local payload
  payload=$(jq -nc --arg sha "$3" --arg status "$4" --arg conclusion "$5" --arg title "$6" \
    --arg summary "$7" --arg url "${8:-}" '
    {name: "pr-gate-runner", head_sha: $sha, status: $status, output: {title: $title, summary: $summary}}
    + (if $conclusion == "" then {} else {conclusion: $conclusion} end)
    + (if $url == "" then {} else {details_url: $url} end)')
  api POST "/repos/$1/$2/check-runs" "$payload" || true
}

# gate_progress_watch LOG STEPS_TSV WORKER_PID OWNER REPO SHA PLANNED_TSV DETAILS_URL — while the
# worker runs, record steps every 2 s and post the checklist when a step starts (and at least
# every 2 minutes, so "so far" stays current). Run in the background; it ends with the worker.
gate_progress_watch() {
  local log=$1 steps=$2 worker=$3 owner=$4 repo=$5 sha=$6 planned=$7 url=$8 last=0 now current
  # The runner's exit and signal handlers finish the attempt as interrupted. This subshell must
  # never run them: stopping the watcher would mark a gate that is about to record its real result.
  trap - EXIT TERM INT HUP
  while kill -0 "$worker" 2>/dev/null; do
    now=$(date +%s)
    if gate_steps_record "$log" "$steps" "$now" || ((now - last >= 120)); then
      current=$(tail -n 1 "$steps" 2>/dev/null | cut -f2-)
      gate_progress_check_run "$owner" "$repo" "$sha" in_progress "" "Gate running: ${current:-starting}" \
        "$(gate_progress_summary "$steps" "$planned" running "$now")" "$url"
      last=$now
    fi
    sleep 2
  done
}
