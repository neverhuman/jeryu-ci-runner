# pr-gate: a `<repo>/required` result per (commit, base)

Status: **design, awaiting approval. No code ships with this document.**

This redoes step 3 of todo b31bc8, which was parked as jeryu-ci-runner#147 (head 938afa3) after its
final review round found a new high. pr-gate stays at its published, base-agnostic behaviour: one
commit open as several pull requests is proved once, against `main`, and that one status answers
for all of them. Nothing below changes that until the operator turns the switch in section 0.

The findings are the review of #147 at 938afa3; the two earlier holds (580222d, 5274e75) are
subsumed. Code references are to `ops/pr-gate/bin/` on `main`.

## What the forge gives us (read from source, not from author text)

- A status row carries `base: Option<String>`. `None` speaks for every base
  (jeryu-core `model/checks.rs`, `CommitStatus::base`, `status_answers_for_base`).
- Among the rows that answer for a base, the latest `updated_at` wins whatever kind it is
  (`current_status_for_base`). So a base-less `error` posted later reds every base, and a base-less
  `success` is green for every base until a later row replaces it.
- Branch protection takes its status through `current_status_for_base`
  (`branch_protection/evaluate.rs:228`), and `merge_overrides.rs:170` does the same.
- `POST .../statuses/:sha` normalises `base` (strips `refs/heads/`, blank is none) and answers 201
  with `commit_status_json`, which always has a `"base"` key (`null` when none was kept).
  `GET .../commits/:ref/status?base=B` filters the rollup the same way.
- jeryu-deploy pins this core at `jeryu-core-v5.0.0-split.22`.

That is the **source** of the pinned tag. It is not a statement about the forge that is deployed
now, which is what section 3 is for.

## 0. One switch, off by default

`PR_GATE_PER_BASE=1` (in `pr-gate.env`) turns on everything below. Off, the runner is byte-for-byte
today's behaviour, including the shared-head fallback to `main` (`cbase="*N"`,
`resolve_proof_base`'s `'*'[0-9]*` case). Every implementation step is written so its tests run
with the switch both ways. The operator sets it only after the probe in section 3 has passed
against the forge the runner talks to, and records the probe's output in the rollout note. A runner
never decides this itself from a response it can influence.

## 1. HIGH: attempt keys, discharge and recovery per (sha, base)

**Cause.** `gate_attempt_key` keys `main` as `<o>-<r>-<sha>` and any other base as
`<o>-<r>-<sha>.base-<h12(branch)>-<basesha>`. `gate_discharge_other_keys` (state.sh:360) treats
every key of the sha but the current one as stale, which is right when a base moved or a PR was
retargeted and wrong when two bases are live. It marks the sibling's unpublished receipts
`superseded_by`, nulls `recovery_required`, and `gate_recover` (state.sh:1122) then skips them for
good. `keep_green` (runner.sh:1809) still sees the old green and posts no pending.

**Design.**

1. *The key names the base the status is posted for*, not only the proof base. For
   `PR_GATE_PER_BASE=1` it is `<o>-<r>-<sha>` for `main` and
   `<o>-<r>-<sha>.base-<h12(posted base)>-<proof base sha, or "main">` otherwise. The suffix shape
   is unchanged for non-main protected bases, so keys written before the switch stay readable and
   `gate_lock`'s name check needs only to accept the `main` literal in the last field. A PR into an
   unprotected base proves against `main` but posts for its own base, so it gets its own key.
2. *Liveness is a set, taken from the listing.* While listing, before the `--pr`/`--repo` filters
   run, the runner records `live_bases["<o>/<r>@<sha>"]` = the h12 of every open PR's base for that
   head, every merge-queue entry's base, and the branch of a `--branch` run. The `--pr` filter does
   not hide a sibling.
3. *`gate_discharge_other_keys` takes the live set.* A key is discharged only if (a) its h12 is not
   in the live set (retargeted or closed), or (b) its h12 is live but its proof-base sha differs from
   the current key's (the same base moved). A key whose base is live and unchanged is another PR's
   key: it is left alone, its lock being held is not a reason to defer this head (that was `rc=1`),
   and its receipts stay recoverable.
4. *Recovery is already per key* (`gate_recover` walks `$gate_key_dir`). With 3, the main key's
   unpublished failure survives the release PR's gate and is published by `gate_recover` the next
   time the main PR is processed, before its status snapshot is read (runner.sh:1651 precedes the
   read at 1710). `keep_green` therefore sees the failure, not the old green. Nothing else reads
   across keys.
5. `last-result.json` discharge in the same function follows the same rule.

**Tests** (new `test-pr-gate-per-base.sh`, forge fixture that records posts):
- Two PRs, same head, bases `main` and `release/v1`, switch on: main-key gate fails, the
  publication gets 503 on every attempt; the release PR is gated next. The main-key receipt is not
  `superseded_by`, still has `recovery_required`; the next main tick publishes the failure and the
  newest answering row for `main` is the failure.
- Same setup with the release gate running while the main key's lock is held by another slot: the
  release head is gated, not deferred.
- Retarget (PR moves `release/v1` to `main`): the `release/v1` key is discharged and recorded as
  superseded, never deleted. Base moves (proof-base sha changes): the old key of that base is
  discharged.
- `--pr N` on one of two sibling PRs does not discharge the other's key.
- Switch off: the existing discharge tests are unchanged and still pass.

## 2. MEDIUM: `--branch` listing read and `branch_green`

**Cause.** runner.sh:829-845 reads `.../commits/<tip>/status` with no base and skips the tip if any
own success exists, so a `main` green skips a release-line tip. `branch_green` (runner.sh:391,
read at 1275 and 1601) is keyed by `owner/repo@sha` alone.

**Design.** One helper decides every read, so the next call site cannot forget:
`status_answers_for_base <snapshot> <base>` is a jq filter applied **client-side** to the rows,
with the forge's rule (no `base` key or null: answers; otherwise equal after stripping
`refs/heads/`). `gate_newest_runner_status` and `gate_newest_is_own_success` gain a base argument
and use it; `?base=` is added to the GET as an optimisation only. Filtering on the client means an
older forge that ignores `?base=` and returns every row is still read correctly, and there is no
read-probe that a forge could pass while evaluating protection differently. The branch listing
passes `$only_branch`; `branch_green` is keyed `owner/repo@sha base`; the keep-green base comparison
(runner.sh:1813) and `retire_stale_base_green` use the same helper. With the switch off the base
argument is empty and the filter accepts every row, as today.

**Tests.** A tip whose only green is `base: main` is gated for `--branch release/v1` and skipped for
`--branch main`; a base-less green skips both; the helper agrees with a table of the forge's
rule, including `refs/heads/` prefixes and `null`.

## 3. MEDIUM: protection must be *evaluated* per base on the deployed forge

Reading per base does not prove evaluating per base: a forge could filter the rollup yet pick
required contexts per commit. The pinned source says it evaluates per base; source is not the
deployed forge, so this is a gate on the switch, not an assertion.

**Probe** `ops/pr-gate/tests/probe-forge-per-base.sh` (not part of `check.sh`: it needs a forge,
a token and a scratch repository, and takes them from its arguments, never from the environment
of a gate). It runs on a scratch repository it creates and deletes:
1. Protect `main` and `release/probe`, both requiring `<repo>/required`; push one commit H; open
   PRs H→`main` and H→`release/probe`.
2. POST `success` with `base=release/probe`. Assert, from the forge's own merge-readiness answer for
   each PR (the same answer the merge button uses, not the status rollup): the release PR is
   satisfied, the `main` PR is not.
3. POST `failure` with `base=main`; assert the release PR is still satisfied and `main` is not.
4. POST a base-less `success`; assert both are satisfied; POST a base-less `error`; assert both are
   not (this is the fail-closed behaviour section 4 relies on).
5. Print the raw 201 body of step 2 and save it as the fixture used in section 5.
It exits non-zero on the first disagreement and prints its evidence; the rollout note quotes it.

**If the probe cannot be run or fails:** the switch stays off and the runner keeps the
listing-time defence for every base: the published pass that posts `pending` over a success proved
against another base before any tree is prepared (`retire_stale_base_green`), which is today's code.
No step of this design removes it while the switch is off, and the step that would stop it
applying to per-base rows (rows that carry their own base) is only reachable with the switch on.

## 4. MEDIUM: the base-not-kept supersede

**Cause (in #147).** A forge that acknowledges a status but does not keep its base has stored a
base-less row, green for every base. The runner posted an `error` over it with plain `api`, threw
away the answer and wrote `code=base-dropped` regardless.

**Design.**
1. The supersede is posted with `gate_api_retry`, which bounds retries at `STATUS_ATTEMPTS` and
   clamps them.
2. Its outcome is recorded as it happened: `.publication.base_supersede = {http_status, fault}`
   with `gate_publication_fault`'s fixed words. Only a 201 with an id marks it done. Anything else
   leaves `recovery_required` set (`"base-less status not superseded"`), so `gate_recover` posts it
   again first on the next tick, before anything else. Done is recorded after the action.
3. *What it does to sibling bases:* it is base-less, so it reds every base of the sha, deliberately.
   The row it replaces was already green for every base, so sibling PRs were already being answered
   by a result that was not theirs; reding them is the fail-closed correction, and they re-gate. A
   base-scoped `error` cannot do this job: the base-less green would still answer for the sibling
   and, being older, only loses to rows that answer for the same base.
4. A dropped base means the forge is not per-base, so the runner writes
   `$HOME_DIR/cache/forge-no-per-base`; while it exists the switch is treated as off (the runner
   says so each tick) until the operator re-runs the probe and removes it. This bounds the
   supersede to once per episode instead of once per gate.

**Tests.** Forge fixture that drops `base`: 503 twice then 201 (retried, recorded 201); 503 on
every attempt (receipt keeps `recovery_required` and `fault: forge-unavailable`, next tick
reposts); 403 (rejected, recorded as such, not `base-dropped`). After a dropped base, a sibling
base's newest answering row is the `error`.

## 5. LOW findings

- **201 body must not be required to echo `base`.** From source it does (`"base"` is always
  present, `null` if dropped, stored without `refs/heads/`), and the probe saves that response as
  `tests/fixtures/forge-status-201.json`, so the test no longer uses a fake that echoes the
  payload. The runner still does not trust the body alone: when `base` is absent or differs, it
  reads `GET .../commits/<sha>/status?base=<b>` once and accepts the post if the row with the 201's
  id is there with that base; only when both say otherwise is the base treated as dropped (section
  4). Test: a forge that stores the base but omits it from the 201 is accepted; one that drops it
  is superseded.
- **`retire_stale_base_green` on a fallback base posts base-less pending.** Every pending the
  runner posts, here and at gate start, carries the base of the key it belongs to, or none only
  when the switch is off. A fallback-to-`main` PR into an unprotected base posts `pending` for
  that base, so it cannot red a sibling's per-base green. Test: sibling with a valid
  `release/v1` green keeps it while a fallback PR's pending is posted.
- **Dead `'*'*` protection-base case** (runner.sh:1660). With the switch on, `cbase` is never
  `*N`; with it off the case is live and stays. It is deleted in the final step, together with the
  rest of the switch-off path, not earlier.
- **Weakened unfetchable-base assertion.** The test keeps `all(.state == "pending" and
  (.description | startswith("its base changed")))` and adds `.base == "<requested>"`; no step
  changes it in the commit that changes the behaviour.

## Order of work: one small PR per step

0. This document, plus the probe script (not wired into `check.sh`). **Approval needed, and the
   probe run against the deployed forge, before step 1.**
1. Section 2's client-side base filter and its table test. Switch off everywhere, no behaviour
   change; the helper is used by every status read.
2. Section 1: key naming, live set, discharge. Behind the switch. The HIGH and its tests.
3. Section 4 and section 5's publication items: supersede, read-back, scoped pending. Behind the
   switch.
4. Operator turns the switch on after a probe receipt; one release of soak.
5. Remove the switch-off path: `*N` fallback, dead case, `forge-no-per-base` marker if the probe is
   now a deploy check.

Each step ends with `just required` green on its own head and states in its PR whether `main` was
green when it was cut.

## Not decided here

- Where the probe's receipt is kept (the rollout note or the deploy repository); both read it the
  same way.
- Whether queue entries need a per-base key of their own or reuse the PR's; the live set covers
  their liveness either way.
