#!/usr/bin/env bash
# Forge lease authority shared by every runner publication path.

# The forge-held claim on the head this slot is about to gate.
#
# Several gate hosts gate at once: each takes an exclusive lease on a head from the forge
# (POST /api/v1/gate-claims) before it posts `pending`, renews it from the moment it is granted
# until the result is published, and releases it on publication. A second host asking for the same
# head is refused, so while every gate host runs this version only the lease holder posts a head's
# required check: a slot whose lease is lost (refused on renewal, or not renewed within one TTL)
# stops its recipe and posts nothing more for that head, and the result is checked against the lease
# once more immediately before publication. A lease nobody renews expires, and any live host with the
# capabilities the repository declares in .jeryu/repo.toml claims that head next, which is how a
# dead host's work is picked up with nobody editing a configuration file. The slot's own lock and
# head claim stay the fast path; diagnostics also take a lease before posting anything.
#
# A forge without the route answers 404 with the typed code `api_route_not_found`; the runner posts
# nothing until the forge is upgraded. Any other 404 (a proxy, a misrouted URL, lost access) is not
# taken as proof of an older forge: the head is left for the next tick and the route is asked again.
# A refusal (another host holds the head, or this host lacks a capability the repository requires)
# leaves the head to that host, and so does a forge that cannot answer at all: posting `pending` for
# a head this host may not be gating is exactly what the lease exists to prevent.
#
# The forge does not replay these routes from an Idempotency-Key, and the runner sends none: an ask
# repeated by the runner that holds the lease (same runner_id) is the renewal, so a runner that lost
# an answer to a timeout asks again and gets the lease it holds, and an ask from any other runner is
# refused while the lease is live.
GATE_CLAIM_ROUTE=1   # 0 once the forge has answered that it has no gate-claims route
GATE_CLAIM_HELD=0    # 1 while this slot holds a lease on the head named below
GATE_CLAIM_OWNER="" GATE_CLAIM_REPO="" GATE_CLAIM_NUMBER=0 GATE_CLAIM_SHA=""
# Which field names the head: a queue entry is claimed by its queue sha, a pull request by its head.
GATE_CLAIM_FIELD=head_sha
GATE_CLAIM_TTL=180
# The renewer's state: `lost` (why the lease was lost) and `worker` (the recipe's process group, which
# a lost lease stops). One directory per slot; the slot lock makes it this run's.
GATE_CLAIM_STATE="$HOME_DIR/cache/gate-claim-slot$SLOT"
gate_claim_renewer=""
gate_claim_payload() {
  jq -nc --arg repo "$GATE_CLAIM_OWNER/$GATE_CLAIM_REPO" --argjson number "$GATE_CLAIM_NUMBER" \
    --arg sha "$GATE_CLAIM_SHA" --arg field "$GATE_CLAIM_FIELD" \
    --arg id "$RUNNER_HOST/slot$SLOT" --arg host "$RUNNER_HOST" \
    '{repo:$repo,number:$number,runner_id:$id,host:$host} + {($field):$sha}'
}
# gate_claim_take OWNER REPO NUMBER SHA FIELD -- 0: this slot holds the head (granted or renewed);
# 1: it does not, and must not gate it now. A lease this slot holds on another head is given back
# first, and every answer that grants nothing leaves GATE_CLAIM_HELD at 0, so the exit handler never
# releases a head this slot was refused.
gate_claim_take() {
  if ((GATE_CLAIM_HELD)) && [[ "$1/$2@$4" != "$GATE_CLAIM_OWNER/$GATE_CLAIM_REPO@$GATE_CLAIM_SHA" ]]; then
    gate_claim_release
  fi
  GATE_CLAIM_OWNER=$1 GATE_CLAIM_REPO=$2 GATE_CLAIM_NUMBER=$3 GATE_CLAIM_SHA=$4 GATE_CLAIM_FIELD=${5:-head_sha}
  ((GATE_CLAIM_ROUTE)) || return 1
  api POST "/api/v1/gate-claims" "$(gate_claim_payload)"
  case "$code" in
    200|201)
      gate_claim_stop_renewer
      GATE_CLAIM_HELD=1
      GATE_CLAIM_TTL=$(jq -r '.ttl_seconds // empty' <<<"$body" 2>/dev/null || true)
      [[ "$GATE_CLAIM_TTL" =~ ^[0-9]+$ ]] && ((GATE_CLAIM_TTL >= 30)) || GATE_CLAIM_TTL=180
      say "$1/$2@$4: gate claim held for ${GATE_CLAIM_TTL}s"
      gate_claim_renewer_start
      return 0;;
  esac
  gate_claim_stop_renewer
  GATE_CLAIM_HELD=0
  case "$code" in
    404)
      if [[ "$(jq -r '.code? // empty' <<<"$body" 2>/dev/null || true)" == api_route_not_found ]]; then
        say "this forge has no gate-claims route; leaving heads untouched until the forge is upgraded"
        GATE_CLAIM_ROUTE=0
        return 1
      fi
      say "$1/$2@$4: asking for its gate claim answered 404 ($(jq -r '.message // .code // empty' <<<"$body" 2>/dev/null || echo 'not a forge answer')); leaving the head for this tick"
      return 1;;
    409)
      say "$1/$2@$4: $(jq -r '.message // "another host holds its gate claim"' <<<"$body" 2>/dev/null || true)"
      return 1;;
    *)
      say "$1/$2@$4: asking for its gate claim answered $code; leaving the head for this tick"
      return 1;;
  esac
}
# gate_claim_renew -- ask for the held lease again, which is the renewal. 0: renewed; 1: refused
# (the lease is lost); 2: no answer that says either (5xx, 000, 429), so the lease may still be held.
gate_claim_renew() {
  ((GATE_CLAIM_HELD)) || return 0
  api POST "/api/v1/gate-claims" "$(gate_claim_payload)"
  [[ ! "$code" =~ ^2 ]] || return 0
  [[ ! "$code" =~ ^(5[0-9][0-9]|000|429)$ ]] || return 2
  return 1
}
# gate_claim_release -- give the head back once its result is published, so the next host does not
# wait out the TTL. Releasing a lease the forge has already forgotten is not an error.
gate_claim_release() {
  gate_claim_stop_renewer
  ((GATE_CLAIM_HELD)) || return 0
  api POST "/api/v1/gate-claims/release" "$(gate_claim_payload)"
  [[ "$code" =~ ^2 ]] \
    || say "releasing the gate claim on $GATE_CLAIM_OWNER/$GATE_CLAIM_REPO@$GATE_CLAIM_SHA answered $code"
  GATE_CLAIM_HELD=0
  return 0
}
# Stop a registered recipe for either background or publication-time lease loss.
# Registration checks the marker too: loss can occur after the pre-spawn check
# but before the parent writes the worker PID, when the renewer sees no worker yet.
gate_claim_stop_worker() {
  local worker=""
  [[ ! -f "$GATE_CLAIM_STATE/worker" ]] || read -r worker <"$GATE_CLAIM_STATE/worker" || true
  [[ ! "$worker" =~ ^[0-9]+$ ]] || kill -TERM -- "-$worker" 2>/dev/null || true
}
gate_claim_mark_lost() {
  printf '%s\n' "$1" | gate_atomic "$GATE_CLAIM_STATE/lost" \
    || say "could not persist the lost-lease marker; stopping its worker anyway"
  say "lost the gate claim on $GATE_CLAIM_OWNER/$GATE_CLAIM_REPO@$GATE_CLAIM_SHA ($1); stopping its gate"
  gate_claim_stop_worker
}
gate_claim_track_worker() {
  printf '%s\n' "$1" | gate_atomic "$GATE_CLAIM_STATE/worker" || return 1
  [[ ! -f "$GATE_CLAIM_STATE/lost" ]] || gate_claim_stop_worker
}

# gate_claim_renew_loop SECONDS RUNNER-PID -- renew every SECONDS while the runner lives. It ends on
# its own when the runner is gone (a `kill -9` of the slot must not leave a process renewing a head
# nobody gates), and when the lease is lost: refused on renewal, or no renewal answered within one
# TTL of the last that was, after which another host may legitimately hold the head. A lost lease is
# recorded in $GATE_CLAIM_STATE/lost and stops the recipe's process group, so the runner abandons the
# attempt and posts nothing more for the head.
gate_claim_renew_loop() {
  local every=$1 runner=$2 last_ok now rc
  ((every >= 10)) || every=10
  last_ok=$(date +%s)
  while kill -0 "$runner" 2>/dev/null; do
    sleep "$every" & wait "$!"
    kill -0 "$runner" 2>/dev/null || break
    rc=0; gate_claim_renew || rc=$?
    now=$(date +%s)
    if ((rc == 0)); then last_ok=$now; continue; fi
    if ((rc == 2 && now - last_ok < GATE_CLAIM_TTL)); then
      say "renewing the gate claim on $GATE_CLAIM_SHA answered $code; retrying"
      continue
    fi
    gate_claim_mark_lost "renewal answered $code, $((now - last_ok))s after the last renewal"
    break
  done
}
# The renewer runs from the grant until publication, through the slot's preparation (prefetch, cache
# restart) as well as the recipe: a lease that lapsed during preparation would let a second host
# gate the head. Each successful take restarts it and clears any previous lost marker.
gate_claim_renewer_start() {
  if [[ -n "$gate_claim_renewer" ]] && kill -0 "$gate_claim_renewer" 2>/dev/null; then return 0; fi
  rm -rf -- "$GATE_CLAIM_STATE" && mkdir -p "$GATE_CLAIM_STATE" && chmod 0700 "$GATE_CLAIM_STATE"
  ( exec 6>&- 7>&- 9>&-; gate_claim_renew_loop "$((GATE_CLAIM_TTL / 3))" "$$" ) </dev/null >>"$GATE_CLAIM_STATE/renewer.log" 2>&1 &
  gate_claim_renewer=$!
}
gate_claim_stop_renewer() {
  [[ -n "$gate_claim_renewer" ]] || return 0
  kill "$gate_claim_renewer" 2>/dev/null || true
  wait "$gate_claim_renewer" 2>/dev/null || true
  gate_claim_renewer=""
}
# gate_claim_lost -- 0 (and prints why) when the background renewer lost this lease.
# Publication authority is checked separately at every write in gate_claim_authorize_path.
gate_claim_lost() {
  ((GATE_CLAIM_HELD)) || return 1
  [[ -f "$GATE_CLAIM_STATE/lost" ]] || return 1
  cat "$GATE_CLAIM_STATE/lost"
}
# gate_claim_abandon WHY -- the attempt this slot ran without its lease ends here: terminal, nothing
# published and nothing owed (another host holds the head and posts its result), and the next tick
# gates the head again if it is still this host's to gate.
gate_claim_abandon() {
  local owner=${owner:?} repo=${repo:?} sha=${sha:?} gate_key_dir=${gate_key_dir:?}
  say "$owner/$repo@$sha: gate claim lost ($1); abandoning attempt $(jq -r '.id' "$gate_receipt") without publishing"
  gate_update --arg why "gate claim lost: $1" --arg at "$(date -u +%FT%TZ)" \
    'if .terminal then . else .terminal=true | .outcome="claim_lost" | .finished_at=$at end
     | .publication.superseded_by=$why | .recovery_required=null' || return
  cat "$gate_receipt" | gate_atomic "$gate_key_dir/last-result.json"
  gate_receipt=""
  GATE_CLAIM_HELD=0
  gate_claim_stop_renewer
}

# Every per-head write passes here, including listing-time retirement, early failures,
# both recovery paths, progress and the EXIT trap. The path/payload names the head;
# inherited globals from a different candidate are never publication authority.
# A transient renewal outage rejects this write but retains terminal outbox evidence.
# Recovery may claim it on a later tick without running the recipe again.
gate_claim_authorize_path() { # method path payload
  [[ "$1" == POST ]] || return 0
  local target_owner target_repo target_sha target_number=0 field=head_sha rc=0
  if [[ "$2" =~ ^/repos/([^/]+)/([^/]+)/statuses/([0-9a-f]{40})$ ]]; then
    target_owner=${BASH_REMATCH[1]} target_repo=${BASH_REMATCH[2]} target_sha=${BASH_REMATCH[3]}
  elif [[ "$2" =~ ^/repos/([^/]+)/([^/]+)/check-runs$ ]]; then
    target_owner=${BASH_REMATCH[1]} target_repo=${BASH_REMATCH[2]}
    target_sha=$(jq -er '.head_sha | select(test("^[0-9a-f]{40}$"))' <<<"${3:-}") || {
      code=lease_unavailable body='invalid publication head'; return 1;
    }
  else
    return 0
  fi
  if [[ "$target_owner/$target_repo@$target_sha" != "$GATE_CLAIM_OWNER/$GATE_CLAIM_REPO@$GATE_CLAIM_SHA" ]] \
      || ((GATE_CLAIM_HELD == 0)); then
    # Progress children only renew their parent's lease; they never acquire or switch heads.
    if [[ -n "${GATE_API_PASSIVE:-}" ]]; then
      code=lease_unavailable body='progress has no lease'; return 1
    fi
    if [[ "${owner:-}/${repo:-}@${sha:-}" == "$target_owner/$target_repo@$target_sha" ]]; then
      target_number=${number:-0}
      [[ ! "${qref:-}" =~ ^refs/queue/ ]] || field=queue_sha
    fi
    heartbeat
    if ! gate_claim_take "$target_owner" "$target_repo" "$target_number" "$target_sha" "$field"; then
      code=lease_unavailable body='publication needs a granted lease'; return 1
    fi
  fi
  # The background renewer may have detected a definitive loss since the last write.
  if [[ -f "$GATE_CLAIM_STATE/lost" ]]; then
    code=lease_unavailable body='publication lease was lost'
    say "$target_owner/$target_repo@$target_sha: $body; posting nothing"
    return 1
  fi
  gate_claim_renew || rc=$?
  if ((rc == 0 && GATE_CLAIM_HELD)); then return 0; fi
  if ((rc == 2)); then
    # Nothing is published while authority is uncertain. gate_publish retains recovery_required.
    code=503 body='publication lease renewal unavailable; retain result for recovery'
  else
    gate_claim_mark_lost "publication renewal refused (HTTP $code)"
    code=lease_unavailable body='publication lease renewal refused'
  fi
  say "$target_owner/$target_repo@$target_sha: $body; posting nothing"
  return 1
}

