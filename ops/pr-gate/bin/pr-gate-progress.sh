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
#   ✓ jankurai pin drift check · 4s
#   ▸ cargo clippy · 1m12s so far
#   ○ cargo test · usually 3m05s
#
# What is published is NOT the log. The recipe that prints these lines is the head's own, and runs as
# the gate user, so a head could print `==> <a credential>` and have it posted to its own PR. A step
# is therefore named on the forge only when its text occurs literally in the repository's gate
# sources on protected main (gate_step_vocabulary: the recipe files main's reviewers approved), and
# only within a short charset and length; any other step is published as "step N". The real text
# stays in steps.tsv on the runner, like the log (see gate_failure_cause in pr-gate-state.sh: the
# same rule, nothing free-form from the log is ever published).
#
# Times are when the line appeared, polled every couple of seconds: good to a few seconds, which
# is what deciding whether a long, low-value step should stay in the required gate needs. A green
# attempt's step times become the repo's "usually" list (cache/steps-<owner>__<repo>.tsv), which
# is also where the steps still to come are named. pr-gate-steps-report.sh summarises every
# attempt's steps.tsv per repo, on the runner.
#
# Sourced by pr-gate-runner.sh. The posting helpers use its `api`; the rest is pure text.

# How much of the checklist is ever published: steps shown, and characters per step name.
GATE_STEPS_SHOWN=60
GATE_STEP_NAME_MAX=80
# Throttle for live posts: at most one per GATE_PROGRESS_MIN_GAP seconds, and at least one per
# GATE_PROGRESS_MAX_GAP while the gate runs (so "so far" stays current).
GATE_PROGRESS_MIN_GAP=${GATE_PROGRESS_MIN_GAP:-15}
GATE_PROGRESS_MAX_GAP=${GATE_PROGRESS_MAX_GAP:-120}

# A step line can carry run-specific text: a mktemp directory ("test temp directories on
# /dev/shm/jeryu-pr-ci.MIIRKT"), a digest, a result ("jankurai score=88"). Compared as written, the
# same step is a new one every attempt: it never matches its "usually" entry, and the report gives
# each run its own row. A step's key replaces that text with a placeholder; it is what steps are
# compared and grouped by. steps.tsv and the published names keep the text as written. Repetitions
# are spelled out because not every awk supports {n,}.
GATE_STEP_KEY_AWK='
function step_key(s,    hex) {
  hex = "[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]+"
  gsub(/(\/dev\/shm|\/var\/tmp|\/tmp)\/[^ ]*/, "<tmp>", s)
  gsub(hex, "<hex>", s)
  gsub(/=[0-9]+(\.[0-9]+)?/, "=<n>", s)
  return s
}'

# gate_step_keys — each step name on stdin, one per line, as its key (GATE_STEP_KEY_AWK).
gate_step_keys() { LC_ALL=C awk "$GATE_STEP_KEY_AWK"' { print step_key($0) }'; }

# gate_step_markers LOG — the step lines of a recipe log, in order, one per line:
#   [pr-ci] <step>                       (jobs=N) prefixes dropped
#   [ci] required|fast lane: <step>
#   ==> <step>
#   > <pkg>@<version> <script>[ <dir>]   npm/pnpm's run banner; the step is "npm <script>"
# The closing "<repo> OK" / "PASS — ..." banners are not steps. Tabs and control characters become
# spaces, so a step name is always one TSV field. Only complete (newline-terminated) lines count: a
# line still being written is read on the next poll, whole.
gate_step_markers() {
  local size last
  [[ -f "$1" ]] || return 0
  size=$(stat -c %s -- "$1" 2>/dev/null) || return 0
  ((size > 0)) || return 0
  # The log only grows, so the byte at size-1 is final: it says whether the snapshot ends a line.
  last=$(tail -c "+$size" -- "$1" | head -c 1 | od -An -tx1 | tr -d ' \n')
  head -c "$size" -- "$1" | LC_ALL=C awk -v partial="$([[ "$last" == 0a ]] && printf 0 || printf 1)" '
    function emit(step) {
      gsub(/[\001-\037\177]/, " ", step)
      sub(/ +$/, "", step)
      if (step == "" || step ~ / OK$/ || step ~ /^PASS( |$)/ || step == previous) return
      print step; previous = step
    }
    function line(l,    s, f) {
      sub(/\r$/, "", l)
      if (l ~ /^\[pr-ci\] /) { s = substr(l, 9); sub(/^\(jobs=[0-9]+\) /, "", s); emit(s); return }
      if (l ~ /^\[ci\] (required|fast) lane: /) { s = l; sub(/^\[ci\] (required|fast) lane: /, "", s); emit(s); return }
      if (l ~ /^==> /) { emit(substr(l, 5)); return }
      # npm prints "> name@version script" (pnpm adds the directory), then "> command". Only the
      # banner, whose first word is a package at a version, names a step.
      if (l ~ /^> @?[A-Za-z0-9._\/-]+@[0-9][^ ]* [^ ]+( |$)/) { split(l, f, " "); emit("npm " f[3]) }
    }
    NR > 1 { line(held) }
    { held = $0 }
    END { if (NR > 0 && !partial) line(held) }
  '
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

# gate_fmt_secs SECONDS — 7s, 1m05s, 1h02m. Anything not a whole number reads as 0s.
gate_fmt_secs() {
  local s=$1
  [[ "$s" =~ ^[0-9]{1,12}$ ]] || s=0
  s=$((10#$s))
  if ((s >= 3600)); then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif ((s >= 60)); then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"; fi
}

# gate_step_vocabulary REPO_DIR BASE OUT — the text a step may be published as: every gate source of
# BASE (protected main), concatenated into OUT. A head cannot add to it, because main is reviewed.
# The sources are the recipe entry points and what they run: Justfiles, ops/, scripts/, Makefiles and
# package.json (npm script names). Blobs over 1 MiB, and anything past 8 MiB in all, are left out:
# a step they alone name is published as "step N". OUT is written even when empty.
gate_step_vocabulary() {
  local dir=$1 base=$2 out=$3
  : >"$out" || return 1
  git -C "$dir" ls-tree -r -l "$base" 2>/dev/null | LC_ALL=C awk '
    {
      tab = index($0, "\t"); path = substr($0, tab + 1); split(substr($0, 1, tab - 1), m, " ")
      if (m[2] != "blob" || m[4] !~ /^[0-9]+$/ || m[4] + 0 > 1048576) next
      if (path ~ /(^|\/)([Jj]ustfile|Makefile|package\.json)$/ || path ~ /\.(just|mk)$/ || path ~ /^(ops|scripts)\//) {
        if ((total += m[4]) > 8388608) exit
        print m[3]
      }
    }' | git -C "$dir" cat-file --batch 2>/dev/null >"$out" || true
}

# gate_step_public VOCAB INDEX TEXT — the name a step is published under: TEXT when it occurs
# literally in VOCAB (an npm step: its script name does), is in the step charset, and is cut to
# GATE_STEP_NAME_MAX characters; otherwise "step INDEX". No vocabulary publishes no names at all.
gate_step_public() {
  local vocab=$1 index=$2 text=$3 known=0 charset='^[A-Za-z0-9][]A-Za-z0-9 ._:/@+=,;()<>#%*!?[-]*$'
  if [[ -n "$vocab" && -s "$vocab" && ${#text} -ge 2 && "$text" =~ $charset ]]; then
    if grep -aqF -- "$text" "$vocab"; then known=1
    elif [[ "$text" == "npm "* ]] && grep -aqF -- "${text#npm }" "$vocab"; then known=1; fi
  fi
  if ((known)); then printf '%s' "${text:0:GATE_STEP_NAME_MAX}"; else printf 'step %d' "$index"; fi
}

# gate_progress_summary STEPS_TSV PLANNED_TSV VOCAB STATE END [CAUSE] — the checklist, as published.
# STATE is running, success, or anything else (a failure: the last step is the one that failed). END
# is the epoch the attempt ended at (or now, while running). PLANNED_TSV ("step<TAB>seconds", from
# the repo's last green attempt) names the steps still to come and their usual times; it may be
# absent. Step names go through gate_step_public against VOCAB, and at most GATE_STEPS_SHOWN steps
# are listed (the latest, while running).
gate_progress_summary() {
  local steps=$1 planned=$2 vocab=$3 state=$4 end=$5 cause=${6:-} i n first started took mark tail total=0 usual=0 room left
  local -a at=() name=() plan_name=() plan_secs=() plan_key=()
  local -A seen_name=()
  [[ "$end" =~ ^[0-9]+$ ]] || end=0
  if [[ -f "$steps" ]]; then
    while IFS=$'\t' read -r t s; do
      [[ -n "$s" && "$t" =~ ^[0-9]+$ ]] && { at+=("$t"); name+=("$s"); }
    done <"$steps"
  fi
  if ((${#name[@]})); then
    while IFS= read -r s; do seen_name[$s]=1; done < <(printf '%s\n' "${name[@]}" | gate_step_keys)
  fi
  if [[ -f "$planned" ]]; then
    while IFS=$'\t' read -r s t; do
      [[ "$t" =~ ^[0-9]{1,9}$ ]] || t=0
      [[ -n "$s" ]] && { plan_name+=("$s"); plan_secs+=("$t"); usual=$((usual + 10#$t)); }
    done <"$planned"
  fi
  if ((${#plan_name[@]})); then mapfile -t plan_key < <(printf '%s\n' "${plan_name[@]}" | gate_step_keys); fi
  n=${#name[@]}
  first=0
  ((n <= GATE_STEPS_SHOWN)) || { first=$((n - GATE_STEPS_SHOWN)); printf '… %d earlier steps\n' "$first"; }
  for ((i = first; i < n; i++)); do
    started=${at[$i]}
    if ((i + 1 < n)); then took=$((at[i + 1] - started)); else took=$((end - started)); fi
    ((took < 0)) && took=0
    if ((i + 1 < n)) || [[ "$state" == success ]]; then mark="✓" tail=$(gate_fmt_secs "$took")
    elif [[ "$state" == running ]]; then mark="▸" tail="$(gate_fmt_secs "$took") so far"
    else mark="✗" tail="$(gate_fmt_secs "$took")${cause:+ — $cause}"; fi
    printf '%s %s · %s\n' "$mark" "$(gate_step_public "$vocab" $((i + 1)) "${name[$i]}")" "$tail"
  done
  if [[ "$state" == running ]]; then
    room=$((GATE_STEPS_SHOWN - (n - first))) left=0
    for ((i = 0; i < ${#plan_name[@]}; i++)); do
      [[ -n "${seen_name[${plan_key[$i]}]:-}" ]] && continue
      if ((room <= 0)); then left=$((left + 1)); continue; fi
      printf '○ %s · usually %s\n' "$(gate_step_public "$vocab" $((i + 1)) "${plan_name[$i]}")" "$(gate_fmt_secs "${plan_secs[$i]}")"
      room=$((room - 1))
    done
    ((left == 0)) || printf '… %d more to come\n' "$left"
  fi
  ((n > 0)) && total=$((end - at[0]))
  ((total >= 0)) || total=0
  if [[ "$state" == running ]]; then
    printf '%d of %s steps · %s so far%s\n' "$n" "$( ((${#plan_name[@]} > n)) && printf %d "${#plan_name[@]}" || printf '%d+' "$n")" \
      "$(gate_fmt_secs "$total")" "$( ((usual > 0)) && printf ' · usually %s' "$(gate_fmt_secs "$usual")")"
  elif ((n == 0)); then
    printf 'The recipe printed no step lines.\n'
  else
    printf '%d steps · %s\n' "$n" "$(gate_fmt_secs "$total")"
  fi
}

# gate_progress_current STEPS_TSV VOCAB — the running step's published name, or nothing.
gate_progress_current() {
  local n text
  [[ -s "$1" ]] || return 0
  n=$(grep -c . "$1" || true)
  text=$(tail -n 1 "$1" | cut -f2-)
  [[ -n "$text" ]] && gate_step_public "$2" "$n" "$text"
}

# gate_steps_learn STEPS_TSV END PLANNED_TSV — after a green attempt, its steps and times become
# the repo's planned list (the next attempt's "usually"). END must be the attempt's own recorded end
# (steps.end); an attempt without one teaches nothing.
gate_steps_learn() {
  local steps=$1 end=$2 planned=$3 i n
  local -a at=() name=()
  [[ -s "$steps" && "$end" =~ ^[0-9]+$ ]] || return 0
  while IFS=$'\t' read -r t s; do [[ -n "$s" && "$t" =~ ^[0-9]+$ ]] && { at+=("$t"); name+=("$s"); }; done <"$steps"
  n=${#name[@]}
  ((n > 0)) || return 0
  mkdir -p -- "$(dirname -- "$planned")"
  {
    for ((i = 0; i < n; i++)); do
      if ((i + 1 < n)); then printf '%s\t%d\n' "${name[$i]}" $((at[i + 1] - at[i]))
      else printf '%s\t%d\n' "${name[$i]}" $((end - at[i])); fi
    done
  } >"$planned.tmp.$BASHPID" && mv -f -- "$planned.tmp.$BASHPID" "$planned"
}

# gate_planned_path OWNER REPO — where a repo's planned steps live.
gate_planned_path() { printf '%s/cache/steps-%s__%s.tsv\n' "$HOME_DIR" "$1" "$2"; }

# gate_checks_url OWNER REPO NUMBER PR_JSON — the checks page of exactly that pull request, from the
# html_url the forge returned for it, or nothing. A URL that is not this PR's own page links nothing.
gate_checks_url() {
  local url
  url=$(jq -r '.html_url // ""' <<<"$4" 2>/dev/null) || return 0
  url=${url%/}
  [[ "$3" =~ ^[0-9]+$ && "$url" =~ ^https://[A-Za-z0-9.:-]+(/[A-Za-z0-9._-]+)*/$1/$2/pulls?/$3$ ]] || return 0
  printf '%s/checks' "$url"
}

# gate_progress_check_run OWNER REPO SHA STATUS CONCLUSION TITLE SUMMARY [DETAILS_URL] — post one
# `pr-gate-runner` check run. The forge keeps the newest run per name, so posting again replaces
# what the PR shows. Best effort: a refused progress post never affects the gate, and a link the
# forge refuses (422) is dropped rather than losing the post.
gate_progress_check_run() {
  local payload url=${8:-}
  while :; do
    payload=$(jq -nc --arg sha "$3" --arg status "$4" --arg conclusion "$5" --arg title "${6:0:200}" \
      --arg summary "${7:0:16000}" --arg url "$url" '
      {name: "pr-gate-runner", head_sha: $sha, status: $status, output: {title: $title, summary: $summary}}
      + (if $conclusion == "" then {} else {conclusion: $conclusion} end)
      + (if $url == "" then {} else {details_url: $url} end)')
    api POST "/repos/$1/$2/check-runs" "$payload" || true
    [[ "${code:-}" == 422 && -n "$url" ]] || return 0
    url=""
  done
}

# gate_progress_watch LOG STEPS_TSV WORKER_PID OWNER REPO SHA PLANNED_TSV VOCAB DETAILS_URL — while the
# worker runs, record steps every 2 s and post the checklist when a step starts, at most once per
# GATE_PROGRESS_MIN_GAP seconds and at least every GATE_PROGRESS_MAX_GAP. Run in the background; it
# ends with the worker.
#
# These posts are the only frequent writes this runner makes, so they are polite about the forge's
# shared rate limit (pr-gate-backoff.sh): none is sent while a back-off is running, and an accepted
# one never clears it (GATE_API_PASSIVE), since a write going through says nothing about reads.
gate_progress_watch() {
  local log=$1 steps=$2 worker=$3 owner=$4 repo=$5 sha=$6 planned=$7 vocab=$8 url=$9 last=0 now due=0
  # The runner's exit and signal handlers finish the attempt as interrupted. This subshell must
  # never run them: stopping the watcher would mark a gate that is about to record its real result.
  trap - EXIT TERM INT HUP
  # Only the runner owns its head, repository and slot locks. A watcher child
  # (for example its polling sleep) can outlive this subshell when it is stopped.
  exec 6>&- 7>&- 9>&-
  export GATE_API_PASSIVE=1
  while kill -0 "$worker" 2>/dev/null; do
    now=$(date +%s)
    gate_steps_record "$log" "$steps" "$now" && due=1
    if { ((due)) && ((now - last >= GATE_PROGRESS_MIN_GAP)); } || ((now - last >= GATE_PROGRESS_MAX_GAP)); then
      if (($(backoff_remaining) == 0)); then
        gate_progress_check_run "$owner" "$repo" "$sha" in_progress "" \
          "Gate running: $(gate_progress_current "$steps" "$vocab" || true)" \
          "$(gate_progress_summary "$steps" "$planned" "$vocab" running "$now")" "$url"
        due=0
      fi
      last=$now
    fi
    sleep 2
  done
}
