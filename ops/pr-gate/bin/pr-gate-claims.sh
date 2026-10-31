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
# 1 once a per-head write was refused because this slot's authority over the head was not current:
# the lease was lost, could not be taken, or renewal did not answer either way. The head may be held
# by another host, so what a retained verdict owes afterwards is decided from this and not from the
# refusal's text (gate_publication_ownership, gate_recover).
GATE_CLAIM_UNCERTAIN=0
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
# Accept only a bounded, explicit TTL from a grant. Unknown grants authorize no writes.
gate_claim_grant_ttl() {
  local ttl
  ttl=$(jq -er '.ttl_seconds | numbers | select(. == floor) | tostring' <<<"$body" 2>/dev/null) || return 1
  [[ "$ttl" =~ ^[0-9]{1,4}$ ]] && ((10#$ttl >= 30 && 10#$ttl <= 3600)) || return 1
  GATE_CLAIM_TTL=$((10#$ttl))
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
      GATE_CLAIM_HELD=0
      gate_claim_grant_ttl || { say "gate claim grant has no bounded TTL; leaving the head for this tick"; return 1; }
      GATE_CLAIM_HELD=1
      GATE_CLAIM_UNCERTAIN=0
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
      say "$1/$2@$4: asking for its gate claim answered 404 (untyped response); leaving the head for this tick"
      return 1;;
    409)
      say "$1/$2@$4: gate claim refused; leaving the head for this tick"
      return 1;;
    *)
      say "$1/$2@$4: asking for its gate claim answered $code; leaving the head for this tick"
      return 1;;
  esac
}
# gate_claim_renew -- ask for the held lease again, which is the renewal. 0: renewed; 1: refused
# (the lease is lost); 2: unknown authority, retried only within the last grant TTL.
gate_claim_renew() {
  ((GATE_CLAIM_HELD)) || return 0
  api POST "/api/v1/gate-claims" "$(gate_claim_payload)"
  case "$code" in
    200|201) gate_claim_grant_ttl && return 0; return 2;;
    409)
      case "$(jq -r '.code? // empty' <<<"$body" 2>/dev/null || true)" in
        claim_held|capability_missing) return 1;;
      esac;;
    404)
      [[ "$(jq -r '.code? // empty' <<<"$body" 2>/dev/null || true)" != api_route_not_found ]] || return 1;;
  esac
  return 2
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
  local worker="" receipt="" parent group
  # Both the registration and the receipt it names must be this user's own plain files: a process
  # group is only stopped on evidence this slot wrote.
  [[ -f "$GATE_CLAIM_STATE/worker" && ! -L "$GATE_CLAIM_STATE/worker" && -O "$GATE_CLAIM_STATE/worker" ]] || return 0
  read -r worker receipt <"$GATE_CLAIM_STATE/worker" || return 0
  [[ "$worker" =~ ^[0-9]+$ && "$receipt" == "$HOME_DIR/attempts/"* && -f "$receipt" && ! -L "$receipt" && -O "$receipt" ]] || return 0
  jq -e --argjson pid "$worker" --arg owner "$GATE_CLAIM_OWNER" --arg repo "$GATE_CLAIM_REPO" \
    --arg sha "$GATE_CLAIM_SHA" '.worker_pid==$pid and .phase=="running" and (.terminal|not)
      and .owner==$owner and .repo==$repo and .sha==$sha' "$receipt" >/dev/null 2>&1 || return 0
  read -r parent group < <(ps -o ppid=,pgid= -p "$worker") || return 0
  [[ "$parent" == "$$" && "$group" == "$worker" ]] || return 0
  kill -TERM -- "-$worker" 2>/dev/null || true
}
# gate_claim_mark_lost KIND WHY -- record that this slot no longer holds the lease. KIND is the
# ownership this answer proves, as its own state and not as text inside WHY: `refused` (the forge
# named another holder, so that host speaks for the head) or `unknown` (any other definitive answer,
# or no answer within one TTL: this slot has no lease and no proof of who does). The kind is written
# before the marker the readers wait on, so a crash in between leaves no marker to misread; a marker
# from a runner that wrote none is classified from the answer it recorded (gate_claim_lost_kind).
gate_claim_mark_lost() {
  printf '%s\n' "$1" | gate_atomic "$GATE_CLAIM_STATE/lost-kind" \
    || say "could not persist the lost-lease ownership; it is read as unknown"
  printf '%s\n' "$2" | gate_atomic "$GATE_CLAIM_STATE/lost" \
    || say "could not persist the lost-lease marker; stopping its worker anyway"
  say "lost the gate claim on $GATE_CLAIM_OWNER/$GATE_CLAIM_REPO@$GATE_CLAIM_SHA ($2); stopping its gate"
  gate_claim_stop_worker
}
gate_claim_track_worker() {
  printf '%s %s\n' "$1" "${gate_receipt:?}" | gate_atomic "$GATE_CLAIM_STATE/worker" || return 1
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
    if ((rc == 0)); then last_ok=$now; every=$((GATE_CLAIM_TTL / 3)); continue; fi
    if ((rc == 2 && now - last_ok < GATE_CLAIM_TTL)); then
      say "renewing the gate claim on $GATE_CLAIM_SHA answered $code; retrying"
      continue
    fi
    gate_claim_mark_lost "$(gate_claim_kind_of "$rc")" \
      "renewal answered $code, $((now - last_ok))s after the last renewal"
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
  printf 'lease renewal no longer grants authority\n'
}
# gate_claim_lost_kind -- the ownership this slot's loss proves: `refused` or `unknown`. Read from
# the state the renewer wrote. A marker left by a runner that recorded no kind is classified from its
# own text: every version wrote the forge's answer into it, and 409 is the only answer that names
# another holder, so a marker carried across a restart keeps the meaning it was written with.
gate_claim_lost_kind() {
  local kind=""
  [[ ! -f "$GATE_CLAIM_STATE/lost-kind" ]] || read -r kind <"$GATE_CLAIM_STATE/lost-kind" || true
  if [[ "$kind" == refused || "$kind" == unknown ]]; then printf '%s\n' "$kind"; return 0; fi
  if grep -q '\b409\b' "$GATE_CLAIM_STATE/lost" 2>/dev/null; then printf 'refused\n'; else printf 'unknown\n'; fi
}
# gate_claim_kind_of RC -- the ownership a gate_claim_renew return code and its `code` prove.
gate_claim_kind_of() { # renew-rc
  if (($1 == 1)) && [[ "$code" == 409 ]]; then printf 'refused\n'; else printf 'unknown\n'; fi
}
# gate_claim_recheck -- ask the forge once more whether this slot still holds the lease, and record a
# definitive answer in the lost marker. Used after long work (a cache upload) that follows the last
# check and precedes the final status; an outage (5xx, 000, 429) records nothing, because publication
# itself retains the verdict for recovery.
gate_claim_recheck() {
  local rc=0
  ((GATE_CLAIM_HELD)) && [[ ! -f "$GATE_CLAIM_STATE/lost" ]] || return 0
  gate_claim_renew || rc=$?
  ((rc != 1)) || gate_claim_mark_lost "$(gate_claim_kind_of "$rc")" "recheck answered $code"
  return 0
}
# gate_claim_abandon WHY -- the attempt this slot ran without its lease ends here, with nothing
# published. What is owed afterwards follows from two facts, and from nothing else:
#
#   * A refusal proves another host holds the head. That host posts the head's result, so nothing is
#     owed here and the next tick gates the head again if it is still this host's to gate.
#   * Otherwise ownership is unknown: this slot has no lease, and an expired lease is claimable by
#     any live host, so another host may already have gated the head. A completed recipe still has a
#     real verdict, which is never discarded: it stays owed, and recovery publishes it only under a
#     fresh lease and only after proving no newer verdict stands (gate_recover). An attempt the lost
#     lease interrupted has no verdict at all, so there is nothing to publish and nothing is owed:
#     publishing one would be this host inventing a result for a head it does not hold.
gate_claim_abandon() {
  local owner=${owner:?} repo=${repo:?} sha=${sha:?} gate_key_dir=${gate_key_dir:?}
  local kind finished=true
  kind=$(gate_claim_lost_kind)
  jq -e '.terminal' "$gate_receipt" >/dev/null || finished=false
  say "$owner/$repo@$sha: gate claim lost ($1); abandoning attempt $(jq -r '.id' "$gate_receipt") without publishing"
  if [[ "$kind" == unknown ]] && [[ "$finished" == true ]]; then
    gate_update --arg why "gate claim ownership unknown: $1" \
      '.recovery_required=$why | .publication.ownership="unknown"' || return
  else
    gate_update --arg why "gate claim lost ($kind): $1" --arg at "$(date -u +%FT%TZ)" \
      'if .terminal then . else .terminal=true | .outcome="claim_lost" | .finished_at=$at end
       | .publication.superseded_by=$why | .publication.ownership=null | .recovery_required=null' || return
  fi
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
      GATE_CLAIM_UNCERTAIN=1
      code=lease_unavailable body='publication needs a granted lease'; return 1
    fi
  fi
  # The background renewer may have detected a definitive loss since the last write.
  if [[ -f "$GATE_CLAIM_STATE/lost" ]]; then
    GATE_CLAIM_UNCERTAIN=1
    code=lease_unavailable body='publication lease was lost'
    say "$target_owner/$target_repo@$target_sha: $body; posting nothing"
    return 1
  fi
  gate_claim_renew || rc=$?
  if ((rc == 0 && GATE_CLAIM_HELD)); then GATE_CLAIM_UNCERTAIN=0; return 0; fi
  GATE_CLAIM_UNCERTAIN=1
  if ((rc == 2)); then
    # Nothing is published while authority is uncertain. gate_publish retains recovery_required.
    code=503 body='publication lease renewal unavailable; retain result for recovery'
  else
    gate_claim_mark_lost "$(gate_claim_kind_of 1)" "publication renewal answered $code"
    code=lease_unavailable body='publication lease renewal refused'
  fi
  say "$target_owner/$target_repo@$target_sha: $body; posting nothing"
  return 1
}

