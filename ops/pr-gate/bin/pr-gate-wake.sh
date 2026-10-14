#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pr-gate-wake.sh — start an idle gate slot as soon as a gated head appears or moves.
#
# A slot only looks for work when its timer fires (pr-gate-runner@.timer, 20s after its last tick),
# so a push waited up to ~25s for an idle slot to notice it. This runs from its own short timer
# (pr-gate-wake.timer) and starts pr-gate-runner@N.service on idle slots: one per new or moved head,
# at most every idle slot. The runner then ticks exactly as it would from its timer -- it chooses,
# claims and gates heads itself -- so this decides only WHEN a tick starts, and the slot timers stay
# the fallback: a wake-up nobody acted on costs today's latency and nothing else.
#
# It wakes nothing unless the forge advertises the signal. A forge that answers 404 for gate-wanted
# (a runner newer than its forge) is probed once and remembered for GATE_RUNNER_WAKE_PROBE_TTL seconds
# (default 600), and any other failed look pauses it for a minute: a newer runner against an older
# forge must degrade to its slot timers, never flood the forge. A 429 on any read starts the shared
# back-off (pr-gate-backoff.sh) that every slot honours too.
#
# It learns what became gateable by the forge's signal and the open-PR view:
#
#   1. The forge's own wake-up signal, GET /api/v1/gate-wanted?after=<seq>&wait=<secs>. The forge
#      records a signal the moment it knows a head can be gated -- a push moved a branch, the merge
#      queue built a queue commit, someone asked for a re-gate -- and holds the request open until
#      the next signal, so a push reaches an idle slot in about as long as the push took. One cheap
#      request per wait window, with no per-repo reads.
#   2. With a working signal, every GATE_RUNNER_WAKE_HEADS_EVERY seconds (default 10); without it,
#      only with GATE_RUNNER_WAKE_POLL_HEADS=1 and at most every GATE_RUNNER_WAKE_POLL_INTERVAL
#      seconds (default 30): the cheapest view of "what could be gated" --
#      the open-PR list of every gated repo, the building merge-queue entries and the pending
#      re-gate requests, waking on a line the view gained since the last poll.
#
# Either way the first look after boot or install only records where things stand and wakes nothing,
# because the slot timers already cover the backlog. Later signals are saved before starting slots,
# including when all slots are busy, so the next scheduled tick retains their priority.
#
# A woken slot is told which head it was woken for: one line per new head in
# cache/wake-dispatch, as "<owner/repo> <number|-> <sha|-> <source> <when>". The runner takes one
# line per tick and gates that head first of the ones its own pass found, and dates the queue wait
# its gate.log event reports from <when>. The line decides nothing -- the runner chooses, claims and
# gates heads by its own rules -- so a line nobody took, or one taken by a slot that then found
# better work, costs nothing but today's latency.
#
# It is a separate file for the same reason as pr-gate-heartbeat.sh: the runner and pr-gate-state.sh
# are gate inputs, and waking is not part of any gate's proof. It never takes a gate lock, never
# posts anything, and never touches a slot whose timer is stopped (an install drain stops them).
# Repos come from the runner's own discovery cache (cache/protected-<owner>); GATE_RUNNER_REPOS pins
# a list instead. With no cache yet there is nothing to watch, and the timers carry on alone.
# ---------------------------------------------------------------------------
set -euo pipefail
# Site configuration (forge, credential, owners): see pr-gate-config.sh.
# shellcheck source=ops/pr-gate/bin/pr-gate-config.sh
source "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/pr-gate-config.sh"
pr_gate_load_config
# The credential is sent only to the configured forge: JERYU_BASE may restate it, never redirect it.
CANONICAL="${PR_GATE_FORGE_URL:-}"
CANONICAL="${CANONICAL%/}"
[[ -n "$CANONICAL" ]] || { printf 'wake: PR_GATE_FORGE_URL is not configured (set it in %s)\n' "$PR_GATE_CONFIG_FILE" >&2; exit 2; }
BASE="${JERYU_BASE:-$CANONICAL}"
BASE="${BASE%/}"
[[ "$BASE" == "$CANONICAL" ]] || { printf 'wake refuses a noncanonical credential origin\n' >&2; exit 2; }
TOKEN_FILE="$(pr_gate_path "${JERYU_TOKEN_FILE:-}")"
[[ -n "$TOKEN_FILE" ]] || { printf 'wake: JERYU_TOKEN_FILE is not configured (set it in %s)\n' "$PR_GATE_CONFIG_FILE" >&2; exit 2; }
HOME_DIR="${GATE_RUNNER_HOME:-$HOME/gate-runner}"
# shellcheck source=ops/pr-gate/bin/pr-gate-backoff.sh
source "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/pr-gate-backoff.sh"
OWNERS="${GATE_RUNNER_OWNERS:-}"
PRIMARY_OWNER="${PR_GATE_PRIMARY_OWNER:-}"
STATE="$HOME_DIR/cache/wake-heads"
# The newest gate-wanted sequence this host has already acted on.
SEQ="$HOME_DIR/cache/wake-seq"
# The heads handed to the slots this script started; the runner takes one line per tick.
DISPATCH="$HOME_DIR/cache/wake-dispatch"
# A push to a default branch that found every main-health slot busy, to retry on the next look.
MAIN_PENDING="$HOME_DIR/cache/wake-main-pending"
# Signal deduplication is local to this look and names a concrete PR, never just a pushed SHA.
# Longest the open-PR view may go unread while the signal is working. It costs one list per gated
# repository, so it is read on a short period rather than on every look.
HEADS_EVERY="${GATE_RUNNER_WAKE_HEADS_EVERY:-10}"
[[ "$HEADS_EVERY" =~ ^[0-9]+$ ]] || { printf 'wake: GATE_RUNNER_WAKE_HEADS_EVERY must be a whole number of seconds\n' >&2; exit 2; }
# Seconds to hold the forge's wake-up signal open. Longer than a slot tick, so a waiting host is woken
# by a signal rather than by its own timeout, and well inside the unit's TimeoutStartSec.
WAKE_WAIT="${GATE_RUNNER_WAKE_WAIT:-30}"
# Until when the signal is not asked for again: set to now+TTL by a 404, now+60 by any other bad look.
PAUSE="$HOME_DIR/cache/wake-signal-pause"
PROBE_TTL="${GATE_RUNNER_WAKE_PROBE_TTL:-600}"
POLL_HEADS="${GATE_RUNNER_WAKE_POLL_HEADS:-0}"
POLL_INTERVAL="${GATE_RUNNER_WAKE_POLL_INTERVAL:-30}"
[[ "$PROBE_TTL" =~ ^[0-9]+$ && "$POLL_INTERVAL" =~ ^[0-9]+$ ]] \
  || { printf 'wake: GATE_RUNNER_WAKE_PROBE_TTL and GATE_RUNNER_WAKE_POLL_INTERVAL must be whole numbers of seconds\n' >&2; exit 2; }
[[ "$WAKE_WAIT" =~ ^[0-9]+$ ]] || { printf 'wake: GATE_RUNNER_WAKE_WAIT must be a whole number of seconds\n' >&2; exit 2; }

say() { printf '[gate-wake %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
mkdir -p "$HOME_DIR/cache"
exec 9>"$HOME_DIR/.wake.lock"
flock -n 9 || exit 0
# Rate limited: every read would be refused again, so stand down until the shared back-off passes.
(( $(backoff_remaining) == 0 )) || exit 0
signal_paused() { local until_; until_="$(cat "$PAUSE" 2>/dev/null || true)"; [[ "$until_" =~ ^[0-9]+$ ]] && (( until_ > $(date +%s) )); }
pause_signal() { printf '%s\n' "$(( $(date +%s) + $1 ))" >"$PAUSE"; }
signal_paused && [[ "$POLL_HEADS" != 1 ]] && exit 0

repos="${GATE_RUNNER_REPOS:-}"
if [[ -z "$repos" ]]; then
  for owner in $OWNERS; do
    [[ ! -s "$HOME_DIR/cache/protected-$owner" ]] || repos+=" $(tr '\n' ' ' <"$HOME_DIR/cache/protected-$owner")"
  done
fi
[[ -n "${repos// }" ]] || exit 0

# The repositories this host gates, each as owner/name: a bare name takes the primary owner, and one
# with no owner to take is not gated here. Both paths below compare against this list.
watch=""
for q in $repos; do
  if [[ "$q" != */* ]]; then [[ -n "$PRIMARY_OWNER" ]] || continue; q="$PRIMARY_OWNER/$q"; fi
  watch+=" $q"
done
watch="${watch# }"
[[ -n "$watch" ]] || exit 0

[[ -f "$TOKEN_FILE" && ! -L "$TOKEN_FILE" && "$(stat -c '%a' "$TOKEN_FILE")" == 600 ]] \
  || { printf 'wake credential must be a regular mode-0600 file\n' >&2; exit 2; }
token="$(cat "$TOKEN_FILE")"
[[ "$token" =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || { printf 'wake credential has an invalid bearer-token shape\n' >&2; exit 2; }
auth="$(mktemp)"; now="$(mktemp)"; heads="$(mktemp)"; signalled="$(mktemp)"
trap 'rm -f -- "$auth" "$now" "$heads" "$signalled"' EXIT
chmod 0600 "$auth"
printf 'header = "Authorization: Bearer %s"\n' "$token" >"$auth"
unset token

get() { # path [max-time] -> $body, $code. A 429 starts the shared back-off; while it runs, no request is made.
  local out hdr
  if (( $(backoff_remaining) > 0 )); then code=429 body=""; return 0; fi
  hdr="$(mktemp)"
  out="$(curl --silent --show-error --max-time "${2:-15}" --config "$auth" -H 'Accept: application/json' \
    --dump-header "$hdr" -w '\n%{http_code}' "$BASE$1")" || out=$'\n000'
  code="${out##*$'\n'}" body="${out%$'\n'*}"
  if [[ "$code" == 429 ]]; then backoff_note_429 "$hdr"; elif [[ "$code" =~ ^2 ]]; then backoff_clear; fi
  rm -f -- "$hdr"
}

# Retain head hints before waking any slot, including heads arriving while every slot is busy.
# Append a batch atomically under the reader's lock. Keep the newest DISPATCH_KEEP lines; this is
# bounded priority, not execution authority or a work journal. The runner drops expired/moved heads.
DISPATCH_KEEP=64
dispatch_add() { # heads-file
  local heads="$1" kept
  [[ -s "$heads" ]] || return 0
  exec 5>"$DISPATCH.lock" || return 1
  flock -w 2 5 || { exec 5>&-; return 1; }
  kept=$({ [[ ! -f "$DISPATCH" ]] || cat "$DISPATCH"; cat "$heads"; } | tail -n "$DISPATCH_KEEP") || return 1
  printf '%s\n' "$kept" >"$DISPATCH.tmp" && mv -f -- "$DISPATCH.tmp" "$DISPATCH" || return 1
  exec 5>&-
}

# Start one idle main-health slot when $1 pushes landed on a default branch. This only says WHEN: the
# slot gates whatever main is by then (newest head wins), under the repository lock that keeps it to
# one gate per repository, and a slot already running is left to finish its pass.
#
# A push that finds every main-health slot busy IS remembered (cache/wake-main-pending) and retried
# on later looks, unlike a pull-request signal: the fallback behind main-health is its own timer,
# which runs far apart, so a forgotten push would leave main ungated until then. The memory is one
# bit -- the next pass gates whatever main is by then -- and a host with no main-health slot at all
# keeps nothing.
wake_main_health() { # count
  local want="$1" n slots woke=() slot_state
  slots="${GATE_RUNNER_MAIN_HEALTH_SLOTS:-$(systemctl --user list-units --no-legend --plain --state=active 'pr-gate-main-health@*.timer' \
    | sed -n 's/^pr-gate-main-health@\([0-9]\+\)\.timer.*/\1/p' | sort -n | tr '\n' ' ' || true)}"
  if [[ -z "${slots// /}" ]]; then
    rm -f -- "$MAIN_PENDING"
    ((want > 0)) && say "$want default-branch push(es); this host runs no main-health slot"
    return 0
  fi
  [[ ! -e "$MAIN_PENDING" ]] || want=$((want + 1))
  ((want > 0)) || return 0
  for n in $slots; do
    ((${#woke[@]} < 1)) || break
    slot_state="$(systemctl --user is-active "pr-gate-main-health@$n.service" 2>/dev/null || true)"
    [[ "$slot_state" == inactive || "$slot_state" == failed ]] || continue
    systemctl --user start --no-block "pr-gate-main-health@$n.service" || continue
    woke+=("$n")
  done
  if ((${#woke[@]} > 0)); then
    rm -f -- "$MAIN_PENDING"
  else
    : >"$MAIN_PENDING"
  fi
  say "$want default-branch push(es); main-health slot(s) woken: ${woke[*]:-none idle, kept for the next look}"
}

# Start up to $1 idle slots and say what it did. Idle is: the slot's timer is active (so neither
# drained nor disabled) and its service is neither running nor starting. $3 names the heads, one
# line per wake-up in the same order. Persist all hints first: a fast-starting service must find
# its hint, and the next scheduled tick must still find hints that arrived while all slots were busy.
wake_slots() { # count what [heads-file]
  local want="$1" what="$2" heads="${3:-}" n slot_state woke=() slots
  ((want > 0)) || return 0
  [[ -z "$heads" ]] || dispatch_add "$heads" || {
    say 'cannot retain wake-up hints; leaving this view unacknowledged'
    return 1
  }
  slots="${GATE_RUNNER_SLOTS:-$(systemctl --user list-units --no-legend --plain --state=active 'pr-gate-runner@*.timer' \
    | sed -n 's/^pr-gate-runner@\([0-9]\+\)\.timer.*/\1/p' | sort -n | tr '\n' ' ' || true)}"
  for n in $slots; do
    ((${#woke[@]} < want)) || break
    slot_state="$(systemctl --user is-active "pr-gate-runner@$n.service" 2>/dev/null || true)"
    [[ "$slot_state" == inactive || "$slot_state" == failed ]] || continue
    systemctl --user start --no-block "pr-gate-runner@$n.service" || continue
    woke+=("$n")
  done
  say "$want $what; woke slot(s): ${woke[*]:-none idle}"
}

# ---------------------------------------------------------------------------
# 1. The forge's wake-up signal. $SEQ is the sequence this host already acted on, so one signal buys
# one tick; a sequence that went backwards means the forge restarted and dropped its in-memory
# signals, which is a resync and not a backlog. The forge hands over only repositories this identity
# may read, and of those only the ones this host gates are worth a slot.
# ---------------------------------------------------------------------------
signal=0
if ! signal_paused; then
  after="$(cat "$SEQ" 2>/dev/null || true)"
  [[ "$after" =~ ^[0-9]+$ ]] || after=""
  # The first look asks for whatever is there and does not wait: it has no sequence to wait past yet.
  get "/api/v1/gate-wanted?after=${after:-0}&wait=$([[ -n "$after" ]] && printf '%s' "$WAKE_WAIT" || printf 0)" \
    "$((WAKE_WAIT + 10))"
  if [[ "$code" == 200 ]] && jq -e 'has("seq") and has("signals")' <<<"$body" >/dev/null 2>&1; then
    seq="$(jq -r '.seq' <<<"$body")"
    [[ "$seq" =~ ^[0-9]+$ ]] \
      || { printf 'wake: the forge answered a nonnumeric gate-wanted sequence\n' >&2; exit 2; }
    fresh=0
    if [[ -n "$after" ]] && ((seq >= after)); then
      # shellcheck disable=SC2086  # the watch list is one repository per word, by construction
      jq -r '.signals[]? | select(.repo | IN($ARGS.positional[]))
        | "\(.repo) \(.number // "-") \(.sha) \(.source) \(.at)"' \
        <<<"$body" --args $watch >"$heads"
      fresh="$(grep -c . "$heads" || true)"
      awk '$2 ~ /^[0-9]+$/ { print $1, $2, $3 }' "$heads" >"$signalled"
    fi
    wake_slots "$fresh" 'gate-wanted signal(s)' "$heads"
    # A push to the default branch also wakes a main-health slot: that is the gate on the new head,
    # so a red main surfaces when it happens and not at the next main-health timer tick. Called on
    # every look with the signal, so a push that found the slots busy is retried.
    main_pushes=0
    if [[ -n "$after" ]] && ((seq >= after)); then
      # shellcheck disable=SC2086
      main_pushes="$(jq -r '[.signals[]? | select(.repo | IN($ARGS.positional[]))
        | select(.source == "push" and ((.ref_name // "") | test("^(refs/heads/)?(main|master)$")))] | length' \
        <<<"$body" --args $watch)"
      [[ "$main_pushes" =~ ^[0-9]+$ ]] || main_pushes=0
    fi
    wake_main_health "$main_pushes"
    printf '%s\n' "$seq" >"$SEQ.tmp" && mv -f -- "$SEQ.tmp" "$SEQ"
    signal=1
  else
    case "$code" in
    404) pause_signal "$PROBE_TTL"; say "the forge has no gate-wanted endpoint (HTTP 404); not asking again for ${PROBE_TTL}s" ;;
    429) say "the forge is rate limiting this identity (HTTP 429); standing back" ;;
    *) pause_signal 60; say "no gate-wanted signal from the forge (HTTP $code); pausing 60s" ;;
    esac
  fi
fi
# Without the signal the slot timers carry the work, unless the operator asked for head reads.
if ((signal == 0)); then
  [[ "$POLL_HEADS" == 1 ]] || exit 0
  STAMP="$HOME_DIR/cache/wake-heads-polled"
  (( $(date +%s) - $(stat -c %Y "$STAMP" 2>/dev/null || echo 0) >= POLL_INTERVAL )) || exit 0
  touch "$STAMP"
fi
(( $(backoff_remaining) == 0 )) || exit 0

# ---------------------------------------------------------------------------
# 2. Diff the cheapest view of what could be gated. It is the only source without the signal, and
# with it, the one that sees a pull request opened on a branch that was already pushed (see the
# header). One list per gated repository, so with a working signal it is read on a period rather
# than on every look.
# ---------------------------------------------------------------------------
if ((signal)) && [[ -e "$STATE" ]] \
    && (( $(date +%s) - $(stat -c %Y "$STATE") < HEADS_EVERY )); then
  exit 0
fi
# The current view: one "repo number sha" line per open PR head, "repo number sha queue" per building
# queue entry, "repo number sha regate <requested_at>" per pending re-gate request. A source that
# cannot be read keeps its previous lines, so a forge hiccup neither wakes nor forgets anything.
for q in $watch; do
  get "/api/v1/repos/${q%%/*}%2F${q#*/}/pulls?state=open"
  if [[ "$code" == 200 ]] && jq -e . <<<"$body" >/dev/null 2>&1; then
    jq -r --arg r "$q" '.items[]? | "\($r) \(.number) \(.head_sha)"' <<<"$body" >>"$now"
  else
    { grep -F -- "$q " "$STATE" 2>/dev/null || true; } | { grep -v ' queue$' || true; } >>"$now"
  fi
done
get "/api/v1/merge-queue?state=building"
if [[ "$code" == 200 ]] && jq -e . <<<"$body" >/dev/null 2>&1; then
  jq -r '.entries[]? | "\(.repo) \(.number) \(.queue_sha) queue"' <<<"$body" >>"$now"
else
  { grep ' queue$' "$STATE" 2>/dev/null || true; } >>"$now"
fi
# A re-gate asked for on the forge is a head that could be gated now, so it wakes a slot like a new
# one. Its requested_at is part of the line: asking again for the same head is a new ask, and the
# runner decides whether it still owes it.
get "/api/v1/gate-regate?state=pending"
if [[ "$code" == 200 ]] && jq -e . <<<"$body" >/dev/null 2>&1; then
  jq -r '.requests[]? | "\(.repo) \(.number) \(.head_sha) regate \(.requested_at)"' <<<"$body" >>"$now"
else
  { grep ' regate ' "$STATE" 2>/dev/null || true; } >>"$now"
fi
# An ok-to-test for a contributed head is the moment that head becomes gateable at all, so it wakes a
# slot too. The runner still decides whether the allowance names the current head and a maintainer
# gave it; this only says a tick is worth starting.
get "/api/v1/gate-allowances?state=active"
if [[ "$code" == 200 ]] && jq -e . <<<"$body" >/dev/null 2>&1; then
  jq -r '.allowances[]? | "\(.repo) \(.number) \(.head_sha) allow \(.allowed_at)"' <<<"$body" >>"$now"
else
  { grep ' allow ' "$STATE" 2>/dev/null || true; } >>"$now"
fi
sort -u -o "$now" "$now"

# First poll after boot or install: record the view, wake nothing (the timers cover the backlog).
if [[ ! -e "$STATE" ]]; then cp -- "$now" "$STATE"; exit 0; fi
# One head per line the view gained, for the slot each wakes. The time is "-": this says only when
# the view was read, and the runner dates such a head from the pull request itself, which is what
# makes an opened pull request's queue wait its own wait and not the age of this poll.
comm -13 "$STATE" "$now" \
  | if [[ -s "$signalled" ]]; then
      awk 'NR == FNR { seen[$1 " " $2 " " $3] = 1; next } !seen[$1 " " $2 " " $3]' "$signalled" -
    else cat; fi \
  | awk 'NF >= 3 { print $1, $2, $3, ($4 == "" ? "pr-head" : $4), "-" }' >"$heads"
fresh=$(grep -c . "$heads" || true)
wake_slots "$fresh" 'new or moved head(s)' "$heads"
cp -- "$now" "$STATE.tmp" && mv -f -- "$STATE.tmp" "$STATE"
