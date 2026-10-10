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
# It learns what became gateable from two sources:
#
#   1. The forge's own wake-up signal, GET /api/v1/gate-wanted?after=<seq>&wait=<secs>. The forge
#      records a signal the moment it knows a head can be gated -- a push moved a branch, the merge
#      queue built a queue commit, someone asked for a re-gate -- and holds the request open until
#      the next signal, so a push reaches an idle slot in about as long as the push took. One cheap
#      request per wait window, with no per-repo reads.
#   2. The open-PR list of every gated repo, the building merge-queue entries and the pending
#      re-gate requests, waking on a line that view gained since the last poll. Against a forge
#      without the signal (or one that answered it badly) this is the only source and runs every
#      look, exactly as it did before the signal existed. Alongside the signal it still runs, at
#      most every GATE_RUNNER_WAKE_HEADS_EVERY seconds, because the signal does not cover a pull
#      request OPENED on a branch that was already pushed: the push signal for it arrived before the
#      pull request existed, so the slot it woke found nothing to gate and the pull request then
#      waited for a slot timer. Measured on jeryu-deploy#267 (2026-10-09): opened 18:26:18, gate
#      started 18:31:40. The open-PR view is what shows such a head, and one list per gated
#      repository every few seconds is cheaper than one idle slot tick.
#
# Either way the first look after boot or install only records where things stand and wakes nothing,
# because the slot timers already cover the backlog. Signals arriving while every slot is busy are
# not saved for later for the same reason: the running ticks, and the timers behind them, find that
# work on their own.
#
# A woken slot is told which head it was woken for: one line per started slot in
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
OWNERS="${GATE_RUNNER_OWNERS:-}"
PRIMARY_OWNER="${PR_GATE_PRIMARY_OWNER:-}"
STATE="$HOME_DIR/cache/wake-heads"
# The newest gate-wanted sequence this host has already acted on.
SEQ="$HOME_DIR/cache/wake-seq"
# The heads handed to the slots this script started; the runner takes one line per tick.
DISPATCH="$HOME_DIR/cache/wake-dispatch"
# The heads the signal already woke a slot for, so the open-PR view does not wake a second one.
SIGNALLED="$HOME_DIR/cache/wake-signalled"
SIGNALLED_KEEP=256
# Longest the open-PR view may go unread while the signal is working. It costs one list per gated
# repository, so it is read on a short period rather than on every look.
HEADS_EVERY="${GATE_RUNNER_WAKE_HEADS_EVERY:-10}"
[[ "$HEADS_EVERY" =~ ^[0-9]+$ ]] || { printf 'wake: GATE_RUNNER_WAKE_HEADS_EVERY must be a whole number of seconds\n' >&2; exit 2; }
# Seconds to hold the forge's wake-up signal open. Longer than a slot tick, so a waiting host is woken
# by a signal rather than by its own timeout, and well inside the unit's TimeoutStartSec.
WAKE_WAIT="${GATE_RUNNER_WAKE_WAIT:-30}"
[[ "$WAKE_WAIT" =~ ^[0-9]+$ ]] || { printf 'wake: GATE_RUNNER_WAKE_WAIT must be a whole number of seconds\n' >&2; exit 2; }

say() { printf '[gate-wake %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
mkdir -p "$HOME_DIR/cache"
exec 9>"$HOME_DIR/.wake.lock"
flock -n 9 || exit 0

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
auth="$(mktemp)"; now="$(mktemp)"; heads="$(mktemp)"; trap 'rm -f -- "$auth" "$now" "$heads"' EXIT
chmod 0600 "$auth"
printf 'header = "Authorization: Bearer %s"\n' "$token" >"$auth"
unset token

get() { # path [max-time] -> $body, $code
  local out
  out="$(curl --silent --show-error --max-time "${2:-15}" --config "$auth" -H 'Accept: application/json' \
    -w '\n%{http_code}' "$BASE$1")" || out=$'\n000'
  code="${out##*$'\n'}" body="${out%$'\n'*}"
}

# Hand one head to a slot that was just started. Appended under its own lock, newest last, and the
# file is held to the newest DISPATCH_KEEP lines: a line is worth taking only while the head is still
# the newest thing that happened, and the runner drops a stale one anyway.
DISPATCH_KEEP=64
dispatch_add() { # "<owner/repo> <number|-> <sha|-> <source> <when>"
  local line="$1" kept
  [[ -n "${line// }" ]] || return 0
  exec 5>"$DISPATCH.lock" || return 0
  flock -w 2 5 || { exec 5>&-; return 0; }
  printf '%s\n' "$line" >>"$DISPATCH"
  if kept="$(tail -n "$DISPATCH_KEEP" "$DISPATCH")"; then
    printf '%s\n' "$kept" >"$DISPATCH.tmp" && mv -f -- "$DISPATCH.tmp" "$DISPATCH"
  fi
  exec 5>&-
}

# Start up to $1 idle slots and say what it did. Idle is: the slot's timer is active (so neither
# drained nor disabled) and its service is neither running nor starting. $3 names the heads, one
# line per wake-up in the same order: each started slot is handed the line it was started for, and a
# head with no slot left to take it is not kept for later.
wake_slots() { # count what [heads-file]
  local want="$1" what="$2" heads="${3:-}" n slot_state woke=() slots
  ((want > 0)) || return 0
  slots="${GATE_RUNNER_SLOTS:-$(systemctl --user list-units --no-legend --plain --state=active 'pr-gate-runner@*.timer' \
    | sed -n 's/^pr-gate-runner@\([0-9]\+\)\.timer.*/\1/p' | sort -n | tr '\n' ' ' || true)}"
  for n in $slots; do
    ((${#woke[@]} < want)) || break
    slot_state="$(systemctl --user is-active "pr-gate-runner@$n.service" 2>/dev/null || true)"
    [[ "$slot_state" == inactive || "$slot_state" == failed ]] || continue
    systemctl --user start --no-block "pr-gate-runner@$n.service" || continue
    woke+=("$n")
    [[ -z "$heads" ]] || dispatch_add "$(sed -n "${#woke[@]}p" "$heads")"
  done
  say "$want $what; woke slot(s): ${woke[*]:-none idle}"
}

# ---------------------------------------------------------------------------
# 1. The forge's wake-up signal. $SEQ is the sequence this host already acted on, so one signal buys
# one tick; a sequence that went backwards means the forge restarted and dropped its in-memory
# signals, which is a resync and not a backlog. The forge hands over only repositories this identity
# may read, and of those only the ones this host gates are worth a slot.
# ---------------------------------------------------------------------------
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
    # One head per signal for a repository this host gates, in the order the forge recorded them: a
    # push names the ref it moved and not a pull request, a queue commit and a re-gate name one.
    # shellcheck disable=SC2086  # the watch list is one repository per word, by construction
    jq -r '.signals[]? | select(.repo | IN($ARGS.positional[]))
           | "\(.repo) \(.number // "-") \(.sha) \(.source) \(.at)"' <<<"$body" --args $watch >"$heads"
    fresh="$(grep -c . "$heads" || true)"
    # The heads the signal reported, so the open-PR view below does not wake a second slot for the
    # same push when it next runs. The newest SIGNALLED_KEEP are remembered; an older head is better
    # served by a wake-up it did not need than by a long memory.
    if ((fresh > 0)); then
      cut -d' ' -f3 "$heads" >>"$SIGNALLED"
      remembered="$(tail -n "$SIGNALLED_KEEP" "$SIGNALLED")" \
        && printf '%s\n' "$remembered" >"$SIGNALLED.tmp" && mv -f -- "$SIGNALLED.tmp" "$SIGNALLED"
    fi
  fi
  printf '%s\n' "$seq" >"$SEQ.tmp" && mv -f -- "$SEQ.tmp" "$SEQ"
  wake_slots "$fresh" 'gate-wanted signal(s)' "$heads"
  signal=1
else
  say "no gate-wanted signal from the forge (HTTP $code); reading gated heads instead"
  signal=0
fi

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
sort -u -o "$now" "$now"

# First poll after boot or install: record the view, wake nothing (the timers cover the backlog).
if [[ ! -e "$STATE" ]]; then cp -- "$now" "$STATE"; exit 0; fi
# One head per line the view gained, for the slot each wakes. The time is "-": this says only when
# the view was read, and the runner dates such a head from the pull request itself, which is what
# makes an opened pull request's queue wait its own wait and not the age of this poll.
comm -13 "$STATE" "$now" \
  | if [[ -s "$SIGNALLED" ]]; then grep -v -F -f "$SIGNALLED" || true; else cat; fi \
  | awk 'NF >= 3 { print $1, $2, $3, ($4 == "" ? "pr-head" : $4), "-" }' >"$heads"
fresh=$(grep -c . "$heads" || true)
cp -- "$now" "$STATE.tmp" && mv -f -- "$STATE.tmp" "$STATE"
((fresh > 0)) || exit 0

wake_slots "$fresh" 'new or moved head(s)' "$heads"
