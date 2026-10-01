#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pr-gate-heartbeat.sh — report every gate slot on this host to the forge's /runners page.
#
# The runner heartbeats only when a gate starts and ends, and the forge forgets a runner 180s after
# its last heartbeat, so a slot vanished from /runners for the whole of every gate. Worse, its
# heartbeat carried last.exit_code, which the forge's schema rejects with a plain-text 422 that the
# runner does not log, so after a slot's first finished gate it was never shown at all.
#
# This runs from its own one-minute timer and reads what the runner already leaves on disk: the running
# attempt's receipt (busy, and what it is gating) and slot-N-last.json (the
# last result). It is deliberately a separate file: the runner and pr-gate-state.sh are gate inputs,
# so changing them re-gates every open head, and reporting is not part of any gate's proof.
# It never takes a lock and never posts a status.
#
# It also tells the forge's pipeline event log (POST /api/v1/events, kind gate.log) how each finished
# attempt ended, with the tail of its build.log, so a red gate can be read on the pull request page
# instead of over SSH. The status the runner posts says only red or green; timed_out, inputs_changed
# and recovery_required were visible nowhere but this host. Reporting stays out of the runner for the
# same reason as above. It reads receipts and logs and writes only its own markers under
# cache/events-posted; attempt evidence is never touched. Events are admin-read on the forge, and the
# log is the recipe's own output: the recipe runs under env -i and never sees the credential.
# Each event carries event_id pr-gate:<attempt id>, which the forge deduplicates, so a post whose
# answer was lost is safe to repeat. GATE_RUNNER_EVENTS=0 turns it off.
# ---------------------------------------------------------------------------
set -euo pipefail
# Site configuration (forge, credential, code repo): see pr-gate-config.sh.
# shellcheck source=ops/pr-gate/bin/pr-gate-config.sh
source "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/pr-gate-config.sh"
pr_gate_load_config
# The credential is sent only to the configured forge: JERYU_BASE may restate it, never redirect it.
CANONICAL="${PR_GATE_FORGE_URL:-}"
CANONICAL="${CANONICAL%/}"
[[ -n "$CANONICAL" ]] || { printf 'heartbeat: PR_GATE_FORGE_URL is not configured (set it in %s)\n' "$PR_GATE_CONFIG_FILE" >&2; exit 2; }
BASE="${JERYU_BASE:-$CANONICAL}"
BASE="${BASE%/}"
[[ "$BASE" == "$CANONICAL" ]] || {
  printf 'heartbeat refuses a noncanonical credential origin\n' >&2
  exit 2
}
TOKEN_FILE="$(pr_gate_path "${JERYU_TOKEN_FILE:-}")"
[[ -n "$TOKEN_FILE" ]] || { printf 'heartbeat: JERYU_TOKEN_FILE is not configured (set it in %s)\n' "$PR_GATE_CONFIG_FILE" >&2; exit 2; }
HOME_DIR="${GATE_RUNNER_HOME:-$HOME/gate-runner}"
HOST="$(hostname -s)"
# Slots are whatever pr-gate-runner@N timers are active (list-unit-files shows only the template);
# GATE_RUNNER_SLOTS overrides.
SLOTS="${GATE_RUNNER_SLOTS:-$(systemctl --user list-units --no-legend --plain --state=active 'pr-gate-runner@*.timer' \
  | sed -n 's/^pr-gate-runner@\([0-9]\+\)\.timer.*/\1/p' | sort -n | tr '\n' ' ' || true)}"
if [[ -z "${SLOTS// }" ]]; then printf 'no active pr-gate-runner@N timers\n' >&2; exit 0; fi

[[ -f "$TOKEN_FILE" && ! -L "$TOKEN_FILE" && "$(stat -c '%a' "$TOKEN_FILE")" == 600 ]] || {
  printf 'heartbeat credential must be a regular mode-0600 file\n' >&2
  exit 2
}
auth="$(mktemp)"; trap 'rm -f -- "$auth"' EXIT
chmod 0600 "$auth"
token="$(cat "$TOKEN_FILE")"
[[ "$token" =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || {
  printf 'heartbeat credential has an invalid bearer-token shape\n' >&2
  exit 2
}
printf 'header = "Authorization: Bearer %s"\n' "$token" >"$auth"
unset token
boot_id="$(cat /proc/sys/kernel/random/boot_id)"
boot_epoch="$(awk '$1 == "btime" { print $2; exit }' /proc/stat)"
clock_ticks="$(getconf CLK_TCK)"

controller_matches() { # PID reuse after admission must not make an old receipt busy.
  local pid=$1 admitted=$2 stat epoch ticks
  local -a fields
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  epoch="$(date -u -d "$admitted" +%s 2>/dev/null)" || return 1
  stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
  read -r -a fields <<<"${stat##*) }"
  ticks="${fields[19]:-}"
  [[ "$ticks" =~ ^[0-9]+$ && "$boot_epoch" =~ ^[0-9]+$ && "$clock_ticks" =~ ^[1-9][0-9]*$ ]] || return 1
  ((boot_epoch + ticks / clock_ticks <= epoch))
}

current() { # slot -> the running gate as the forge's `current` object, or null
  local slot=$1 receipt pid pr repo sha admitted
  # Busy means a non-terminal receipt bound to this boot and its original live controller. The slot lock would say the
  # same, but probing it with flock takes it for an instant and can make a runner tick skip.
  receipt=$(find "$HOME_DIR/attempts" -name receipt.json -mmin -300 -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | cut -d' ' -f2- | while read -r f; do
        jq -e --arg s "$slot" --arg boot "$boot_id" '.slot == $s and .boot_id == $boot and (.terminal != true)' "$f" >/dev/null 2>&1 || continue
        pid=$(jq -r '.pid // empty' "$f")
        admitted=$(jq -r '.started_at // empty' "$f")
        if controller_matches "$pid" "$admitted"; then
          printf '%s' "$f"; break
        fi
        printf 'slot %s: unbound controller in non-terminal receipt; recovery required\n' "$slot" >&2
      done) || true
  [[ -n "$receipt" ]] || { printf 'null'; return; }
  repo="$(jq -r '.owner + "/" + .repo' "$receipt")" sha="$(jq -r .sha "$receipt")"
  # The receipt has no PR number; the runner logs it as "preparing owner/repo#N at sha".
  pr=$(journalctl --user -u "pr-gate-runner@$slot" --since -4h -o cat --no-pager 2>/dev/null \
    | sed -n "s|.*preparing $repo#\([0-9]\+\) at $sha.*|\1|p" | tail -1)
  jq -c --argjson pr "${pr:-0}" \
    '{repo:(.owner + "/" + .repo), pr:$pr, sha, recipe:.inputs.recipe, startedAt:.started_at}' "$receipt"
}

last() { # slot -> the forge's `last` object, or null. Its schema has no exit_code and knows only
  # success, failure and error; the runner also records timed_out and inputs_changed.
  local f="$HOME_DIR/cache/slot-$1-last.json"
  if [[ -s "$f" ]] && jq -e . "$f" >/dev/null 2>&1; then
    jq -c '{repo, pr, sha, recipe, seconds, finishedAt,
      conclusion: (if .conclusion == "success" or .conclusion == "failure" then .conclusion else "error" end)}' "$f"
  else
    printf 'null'
  fi
}

post_heartbeat() { # json -> sets $out and $code
  out=$(curl --disable --silent --show-error --max-time 30 --config "$auth" -X POST -H 'Content-Type: application/json' \
    --data "$1" -w '\n%{http_code}' "$BASE/api/v1/runners/heartbeat") || out=$'\n000'
  code="${out##*$'\n'}"
}
# What code this host runs (installed-main.json; see gate_runner_code) and what its gates evaluate
# with (tools.json; see gate_runner_tools), each possibly empty. The library sits beside this script
# in the installed bin. A forge that predates either field refuses the whole heartbeat with 422: that
# slot is retried at once without tools (keeping code), then if still refused without code too, and
# the rest of this tick sends neither refused field. Each fallback is logged once.
# shellcheck source=ops/pr-gate/bin/pr-gate-state.sh
source "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/pr-gate-state.sh" 2>/dev/null || true
runner_code="" runner_tools=""
declare -F gate_runner_code >/dev/null && runner_code=$(gate_runner_code "$HOME_DIR")
declare -F gate_runner_tools >/dev/null && runner_tools=$(gate_runner_tools "$HOME_DIR")

for slot in $SLOTS; do
  body=$(jq -nc --arg id "$HOST/slot$slot" --arg host "$HOST" --argjson slot "$slot" \
    --argjson current "$(current "$slot")" --argjson last "$(last "$slot")" \
    '{runnerId:$id, host:$host, slot:$slot, labels:["pr-gate"], current:$current, last:$last}')
  if [[ -n "$runner_code$runner_tools" ]]; then
    post_heartbeat "$(gate_heartbeat_with "$body" "$runner_code" "$runner_tools")"
  else
    post_heartbeat "$body"
  fi
  if [[ "$code" == 422 && -n "$runner_tools" ]]; then
    printf 'heartbeat tools refused (422); retrying without them\n' >&2
    runner_tools=""
    post_heartbeat "$(gate_heartbeat_with "$body" "$runner_code" "")"
  fi
  if [[ "$code" == 422 && -n "$runner_code" ]]; then
    printf 'heartbeat code refused (422); retrying without it\n' >&2
    runner_code=""
    post_heartbeat "$body"
  fi
  [[ "$code" == 200 ]] || printf 'slot %s: heartbeat answered %s: %s\n' "$slot" "$code" "${out%$'\n'*}" >&2
done

# ---- finished attempts -> pipeline events -------------------------------------------------------
[[ "${GATE_RUNNER_EVENTS:-1}" != 0 ]] || exit 0
POSTED="$HOME_DIR/cache/events-posted"
mkdir -p "$POSTED"
find "$POSTED" -type f -mtime +15 -delete 2>/dev/null || true
EVENT_WINDOW_MIN="${GATE_RUNNER_EVENT_WINDOW_MIN:-60}"
EVENT_MAX="${GATE_RUNNER_EVENT_MAX:-10}"

pr_of() { # slot repo sha -> PR number or null. The receipt has none; the slot's last result or its journal does.
  local slot=$1 repo=$2 sha=$3 pr="" f="$HOME_DIR/cache/slot-$1-last.json"
  if [[ -s "$f" ]]; then
    pr=$(jq -r --arg repo "$repo" --arg sha "$sha" 'select(.repo == $repo and .sha == $sha) | .pr // empty' "$f" 2>/dev/null) || pr=""
  fi
  if [[ -z "$pr" ]]; then
    pr=$(journalctl --user -u "pr-gate-runner@$slot" --since -6h -o cat --no-pager 2>/dev/null \
      | sed -n "s|.*preparing $repo#\([0-9]\+\) at $sha.*|\1|p" | tail -1) || pr=""
  fi
  [[ "$pr" =~ ^[1-9][0-9]*$ ]] && printf '%s' "$pr" || printf 'null'
}

posted=0
while IFS= read -r receipt; do
  ((posted < EVENT_MAX)) || break
  jq -e '.terminal == true and (.id | type == "string")' "$receipt" >/dev/null 2>&1 || continue
  id=$(jq -r .id "$receipt")
  [[ "$id" =~ ^[A-Za-z0-9-]{1,64}$ ]] || continue
  [[ ! -e "$POSTED/$id" && ! -e "$POSTED/$id.rejected" ]] || continue
  slot=$(jq -r '.slot // "0"' "$receipt")
  [[ "$slot" =~ ^[0-9]+$ ]] || continue
  repo=$(jq -r '.owner + "/" + .repo' "$receipt") sha=$(jq -r .sha "$receipt")
  outcome=$(jq -r '.outcome // "error"' "$receipt")
  # The log is the one beside the receipt, never a path read out of it.
  log="$(dirname "$receipt")/build.log"
  tail_bytes=12288; [[ "$outcome" != success ]] || tail_bytes=2048
  tail_file=$(mktemp); log_bytes=0
  if [[ -f "$log" && ! -L "$log" ]]; then
    log_bytes=$(stat -c %s "$log")
    # Keep newlines and tabs; drop other control bytes (colour codes, carriage returns) and bad UTF-8.
    tail -c "$tail_bytes" "$log" | iconv -f utf-8 -t utf-8 -c 2>/dev/null \
      | sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\000-\010\013-\037\177' >"$tail_file" || : >"$tail_file"
  fi
  event=$(jq -c --arg host "$HOST" --arg repo "$repo" --argjson pr "$(pr_of "$slot" "$repo" "$sha")" \
    --rawfile tail "$tail_file" --argjson log_bytes "$log_bytes" '
    (.outcome // "error") as $outcome
    | ((.finished_at // .started_at | fromdateiso8601) - (.started_at | fromdateiso8601)) as $seconds
    | {event_id: ("pr-gate:" + .id), source: "pr-gate", kind: "gate.log", actor: ($host + "/slot" + (.slot // "0")),
       repo: $repo, pr: $pr, sha: .sha, outcome: $outcome, seconds: $seconds,
       needs_human: (.recovery_required != null),
       summary: ($repo + (if $pr == null then "" else "#" + ($pr | tostring) end) + " " + (.inputs.required_context // "gate")
                 + " " + $outcome + " in " + ($seconds | tostring) + "s on " + $host + "/slot" + (.slot // "0")),
       reason: (if .recovery_required == null then null else (.recovery_required | tostring | .[0:1000]) end),
       log_tail: (if $tail == "" then null else $tail end),
       detail: {attempt: .id, sequence, exit_code, execution_kind, recipe: .inputs.recipe, log_sha256, log_bytes: $log_bytes,
                cache: (.cache // null)}}
    | .summary |= .[0:300]' "$receipt" 2>/dev/null) || event=""
  rm -f -- "$tail_file"
  [[ -n "$event" ]] || { printf 'attempt %s: receipt could not be projected to an event\n' "$id" >&2; continue; }
  out=$(curl --disable --silent --show-error --max-time 30 --config "$auth" -X POST -H 'Content-Type: application/json' \
    --data-binary @- -w '\n%{http_code}' "$BASE/api/v1/events" <<<"$event") || out=$'\n000'
  code="${out##*$'\n'}"
  # A forge that predates the route answers 200 with the web app's HTML, so the status alone proves
  # nothing: only the route's own JSON acknowledgement counts as stored.
  if [[ "$code" == 20[01] ]] && ! jq -e '.ok == true' <<<"${out%$'\n'*}" >/dev/null 2>&1; then code=unacknowledged; fi
  case "$code" in
    200|201) : >"$POSTED/$id"; posted=$((posted + 1)) ;;
    422) # The forge will never take this one; say so once and move on.
      : >"$POSTED/$id.rejected"
      printf 'attempt %s: event rejected 422: %s\n' "$id" "$(head -c 300 <<<"${out%$'\n'*}")" >&2 ;;
    *) # A forge without the route is unacknowledged, a refusal answers 401/403, an outage 5xx
      # or 000. None of them will differ for the next receipt, so stop for this tick and retry later.
      printf 'event log answered %s; unreported attempts wait for the next tick\n' "$code" >&2
      break ;;
  esac
done < <(find "$HOME_DIR/attempts" -name receipt.json -mmin "-$EVENT_WINDOW_MIN" -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2-)
