#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pr-gate-backoff.sh — one shared forge back-off for every pr-gate script on this host.
#
# A forge that answers 429 wants fewer requests, not the same ones again on the next tick. Every slot,
# the wake timer and the heartbeat share one identity and so one rate limit, so the back-off is one
# file, cache/forge-backoff ("<until-epoch> <consecutive-429s>"), not a per-process variable.
# Sourced; defines functions only. The caller sets HOME_DIR.
# ---------------------------------------------------------------------------
BACKOFF_FILE="${HOME_DIR:?}/cache/forge-backoff"
BACKOFF_BASE="${GATE_RUNNER_BACKOFF_BASE:-30}"
BACKOFF_CAP="${GATE_RUNNER_BACKOFF_CAP:-900}"

backoff_remaining() { # -> seconds left to wait (0 when clear)
  local until_ n left
  read -r until_ n 2>/dev/null <"$BACKOFF_FILE" || until_=0
  [[ "$until_" =~ ^[0-9]+$ ]] || until_=0
  left=$((until_ - $(date +%s)))
  ((left > 0)) && printf '%s' "$left" || printf 0
}

backoff_clear() { rm -f -- "$BACKOFF_FILE"; }

# backoff_note_429 <response-header-file>: widen the wait. It doubles from BACKOFF_BASE per consecutive
# 429 up to BACKOFF_CAP, and never undercuts a Retry-After (seconds) the forge sent.
backoff_note_429() {
  local hdr=${1:-} until_ n delay retry now
  read -r until_ n 2>/dev/null <"$BACKOFF_FILE" || n=0
  [[ "${n:-}" =~ ^[0-9]+$ ]] || n=0
  ((n < 20)) || n=19
  delay=$((BACKOFF_BASE << n))
  ((delay <= BACKOFF_CAP)) || delay=$BACKOFF_CAP
  retry=$(sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*\([0-9]\{1,6\}\).*/\1/p' "$hdr" 2>/dev/null | tail -1)
  [[ -z "$retry" ]] || { ((retry <= BACKOFF_CAP)) || retry=$BACKOFF_CAP; ((retry <= delay)) || delay=$retry; }
  now=$(date +%s)
  mkdir -p -- "$(dirname -- "$BACKOFF_FILE")"
  printf '%s %s\n' "$((now + delay))" "$((n + 1))" >"$BACKOFF_FILE.tmp.$$" && mv -f -- "$BACKOFF_FILE.tmp.$$" "$BACKOFF_FILE"
}
