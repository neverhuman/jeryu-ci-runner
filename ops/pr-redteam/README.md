# pr-redteam

Review pull requests on the forge named by `JERYU_BASE` at their exact head. Confirmed high or
critical security/correctness findings block. An explicit block verdict always
holds; failed processes, incomplete output and contradictory approvals publish
nothing. Findings and terminal attempt receipts remain available for review.

Where the base branch requires `jankurai/proof`, the quality gate comes first: a
head whose proof fails or failed to score is held with that reason before any
agent budget is spent, and nothing here can approve it. A proof the forge has
queued, is running, or has not started is not a verdict on the head: that head
gets no review and no receipt, and a later pass reviews it once the proof has a
result. Repositories
outside the gate's rollout are unaffected — their proof is reported, not
required. `ops/ci/jankurai-gate.sh` is the same verdict, run locally before the
pull request exists.

## Opt-in held-review handoff

Held-review filing is disabled by default (`REDTEAM_FIX_TODO=0`). A service owner
must qualify the Todoq executable and explicitly select automation author logins
with `REDTEAM_FIX_TODO_AUTHORS` before enabling it. Unknown authors remain with
their author. Drafts, contributions, selected humans with recent activity,
approvals and holds without high or critical findings create no work. A held head
also gets the configured grace period, normally two hours, for an author push.

An enabled pass attempts at most `REDTEAM_FIX_TODO_MAX_PER_PASS` new filings
(default one, maximum nine). It uses the verified Todoq `add` contract with
explicit family, repos, title and priority, plus `--no-triage`; findings do not
enter an extra triage model call. The ask contains bounded high/critical findings
as fenced JSON data and says they are untrusted evidence, never instructions.
The canonical task link comes from the forge's PR read, with an additional
live head check before dispatch intent is recorded. Unavailable metadata, a moved
head or a link outside the configured forge defers filing without consuming it.
It requires the worker to authenticate the still-open PR and original head before
editing, cherry-picking or publishing, follow repository instructions, use its
own worktree and keep any new PR as a draft.

Before dispatch, an atomic, synced `fix-todos/<repo>/<PR>-<head>.json` ledger
records intent. Confirmed output records the id there and in the review receipt.
A failing command, timeout or unrecognised acknowledgement is an UNKNOWN outcome:
it may already have created work, so no automatic retry is allowed. A surviving
prepared record after a crash has the same rule. The ledger survives rereviews.
The owner must reconcile the Todoq queue against the saved ask before any manual
retry. The real CLI has no idempotency key; this source does not claim exactly-once
external delivery.

When the author pushes a new head, a confirmed old task is marked stale through
Todoq's documented `block --note` command. An uncertain annotation is retained
for owner reconciliation rather than repeated. Confirmed ids from older receipts
are imported for this purpose. Blocking a task does not stop a running worker;
the ask's original-head checks remain required. `--dry-run` writes no ledger and
calls no Todoq command; disabling filing also disables all task annotations.

This controller never auto-closes a held PR or replaces its changes-requested
review with a neutral comment. Free-text replacement messages are not closure
proof. A maintainer decides supersession using a complete salvage bundle and
exact repository, original head and landed replacement evidence.

## An owner's recorded decision

Some findings ask for a decision only the repository's owner can make: a policy floor the change
lowers deliberately, a rule the owner has decided to accept here. The agent is right to hold such a
head, and wrong to hold it once the owner has answered.

A same-head effective approval with an explicit `Owner decision: ...` line may
be included as context in the published review when its account is a configured
decision author. PR authors and controller/merger identities are excluded.
The namespace owner and `REDTEAM_OWNER_DECISION_AUTHORS` remain site configuration;
this is an attribution filter, not authority to waive review findings.

The controller preserves the independent verdict and every finding's severity.
No phrase, approval or owner statement clears a high/critical finding, changes
branch protection or authorizes a merge. A changed requirement needs source and
policy review; a held review needs fresh independent evaluation. The published
review and receipt carry the statement without claiming that it cleared a gate.

Review-progress check runs are published only for an internal, non-dry attempt.
The same explicit capability gates start, diff and terminal/error-trap updates;
contributed reviews remain advice and dry runs create no review check runs.

## Contributed pull requests

The GitHub repositories are read-only mirrors of the forge. An outside contributor opens a pull
request there and an importer brings it to the forge, which records its origin on the pull request
row — `origin:contributed`, set by the importer and never by the author. Everything else reads
`origin:internal`.

A contributed pull request is reviewed as carefully as any other and the review is advice: it is
posted as a comment, never an approval or a changes-requested verdict, and this controller neither
queues nor merges it. The forge holds it until a login on its configured maintainer list approves
the exact head; that maintainer merges it. A row carrying neither label reads as contributed,
because no origin is not a reason to approve and land somebody's change;
`REDTEAM_UNMARKED_ORIGIN=internal` is the opt-out for a forge that does not mark origins yet.

Contributed review spend is capped, well below an internal pull request's: one agent review per
head (`--force` included — forcing a second is what the cap exists to prevent), a per-pull-request
budget across heads, and a per-UTC-day budget across every contribution
(`REDTEAM_CONTRIBUTED_BUDGET_USD`, `REDTEAM_CONTRIBUTED_PR_USD`, `REDTEAM_CONTRIBUTED_DAILY_USD`).
A run that failed or produced nothing publishable still counts: it cost money, and retrying it every
pass would cost more. Over a cap the pull request is left for a maintainer, with the cap named in
the log. The ledger is `contributed-spend.tsv` under `REDTEAM_STATE`.

The pull request's title, description, commit messages and diff are the contributor's words. They
are evidence the reviewer reads, never instructions it follows: text that addresses the reviewer,
claims prior sign-off or asks for an approval is itself a critical finding.

pr-redteam also lands what it approved. After the review pass, every open PR
this controller approved at its current head is merged as the merger identity,
once the forge itself says it can merge: approval, required contexts green, no
changes requested. The merge is pinned to the exact reviewed head and the
forge's merge passport, so a PR pushed after approval is never landed — it is
reviewed again at its new head.

Merge eligibility is recomputed on every pass from this controller's own
receipts, independently of the "already reviewed" skip. That skip covers the
review only. A required context that fails on its first attempt and succeeds on
the gate runner's retry is therefore landed on the next pass, with no second
review; the same holds for a head that was behind its base and became
mergeable.

Branches are never rewritten. An approved PR behind a linear-history base is
handed to the forge's merge queue (`REDTEAM_QUEUE=1`, the default), which
replays and gates it without touching anybody's branch. With `REDTEAM_QUEUE=0
REDTEAM_REBASE=1` the controller will instead rebase and force-push such a
branch, leased to the reviewed head; this is off by default because the family's
no-force rule does not permit it, and an empty rebase is never pushed.

The controller never tags, waives checks or posts required statuses.
`REDTEAM_MERGE_TOKEN_FILE` selects the merger credential by path and has no
default: this source is public, so the path is site configuration. Unset or
unreadable, the review pass still runs and nothing is landed. Installation
stages inactive units; it does not authorize or start automated review or
landing.

`REDTEAM_AUTHOR_DOMAINS` (space-separated `owner/name=domain`, empty by default,
also site configuration) restricts a repository to one email domain: a PR there
is reviewed only when every commit in it is authored and committed at exactly
that domain (any case; subdomains and lookalikes do not match). Any other PR is
held once per head with an `author_domain` receipt, before any agent budget is
spent, and is left for a person. Git emails are self-asserted, so this narrows
what the controller approves; who may push is still the forge's decision.
Changing the rules changes the review identity (see "Review identity and
reinstalls" below), so existing receipts requalify.

## Qualification

`bash test/required.sh` runs offline quality-gate, draft-skip, review-identity, verdict, binary-payload,
credential-transport, heartbeat contract, poke, publication/recovery, merge-pass, contributed-origin, owner-decision and installation checks. The actual repository required lane
runs this suite. Tests use local fixture repositories, dummy credentials and
stand-in model/forge processes. They cover malformed and failed model results,
publication refusal, restart, duplicate dispatch, worker loss and changed heads,
and the landing path: approve, a failing required context, that context going
green on a retry, and the merge that follows without a second review. The
contributed-origin suite covers the whole gate: a contribution with a clean
review is posted as advice and stays unmerged, its head gets one agent review
whatever is asked of it, the per-pull-request and per-day budgets each hold the
next head for a maintainer, an unmarked row is treated as contributed, and an
internal pull request is reviewed, approved and merged exactly as before.
The owner-decision suite covers who may record one, what counts as one, which
findings it answers, that the answered findings stay in the published review,
and that another finding — or a mechanical hold — still holds the head.

`test/canary.sh` is a separate paid live-model qualification for the service owner.
It requires the exact pinned CLI and selected model. Offline source qualification
does not establish the live model's accuracy, sandbox confinement, or service
activation approval.

## Commands

```sh
./pr-redteam list
./pr-redteam run --dry-run --repo acme/widget-web --pr 16
./pr-redteam run --repo acme/widget-web --pr 16
./pr-redteam show acme/widget-web 16
./pr-redteam identity
./pr-redteam heartbeat
./pr-redteam poke --dry-run
```

`run` reviews, then lands what it approved, then performs the disabled-by-default
held-review handoff when the service owner has enabled it. `heartbeat` sends one
beat per reviewer slot: a review takes a numbered slot for
as long as it runs, so `/runners` shows `REDTEAM_JOBS` rows (`<id>`, `<id>-2` …)
instead of one row for the whole pass. Each beat follows the forge's runner contract, which refuses a
beat with any field it does not define: `current` and `last` are cut down to
that contract's fields before sending, and a receipt decision the forge has no
reviewer conclusion for (`base_missing`, `author_domain`, `advice`) is sent as
`hold` with the decision in `reason`. A beat also names the code it runs,
`code: {repo, commit}`: the commit comes from `source-commit`, which
`git archive` fills in (`export-subst`), or from a git checkout of this
repository whose `ops/pr-redteam` is unmodified; otherwise `code` is left out. `tools` lists the
`claude` CLI version the last review measured, and is left out before the
first review. `poke` runs every 30 seconds from
`pr-redteam-poke.timer`. Unreviewed heads start `pr-redteam.service` early. A
head's `review` poke is usually used up while its required gate is still
running, and that pass can leave it with no receipt (a jankurai/proof without a
result is waited for). Such a head, still open, ready and with no receipt, gets
one more poke, `ready`, once the forge's merge passport for that exact head is
blocked only by its missing approval or a requested change (any other or
unknown blocker starts nothing); that check reads at most four pull requests
per poke, and none while a review pass is running. A forge that refuses `tools`
or `code` with 422 gets the beat again without them, as the pr-gate runner does.
Landable approvals start `pr-redteam-merge@owner:repo:PR:head.service`, even while
other reviews are running. The instance scopes landing to that repository, PR
and exact reviewed head; operator `--repo`/`--pr` filters therefore remain in
effect. Poke has no merger environment and starts no detached process. The
managed merge unit loads the site's optional `merge.env`, logs to the journal,
and holds both the merge-pass lock and the PR's review lock through publication.
An active rereview defers landing. A failed unit-start request is retried by the
next poke; an accepted start is recorded once per head. Execution failures still
retry through the five-minute review/merge timer. Dry runs consume no poke key.
The merge log reports seconds since the receipt's ISO `reviewed_at` timestamp.

The reviewer skips its own authored PRs, contributed PRs whose review spend is
used up, drafts unless explicitly included, and
successfully posted reviews at the current head with matching controller, prompt,
schema, model, CLI executable and version inputs. Each changed head needs a new
review. A PR whose base branch the forge does not have yet — the shape a new
repository is bootstrapped with, since a first push to the default branch is
refused — is recorded once per head as `base_missing` and left to a person,
rather than failing its fetch again on every pass. The forge receives the exact
expected head and can reject publication if it moved while the model was running. Rejected publication remains retryable.

A skipped draft is reported to the forge as one `pr.skipped` pipeline event per
head, so it appears on the pull request's own timeline instead of only in this
log; `list` and `--dry-run` post nothing. Marking a draft ready for review is
the author's or an admin's move:
`POST /api/v1/repos/{id}/pulls/{number}/ready`.

What each review cost goes to the same event log as one `pr.reviewed` event per
attempt whose agent reported a cost, whatever the decision: `cost_usd`,
`seconds`, `outcome` (the receipt's decision) and, in `detail.usage`, the
session's tokens per model (`input`, `output`, `cache_read`, `cache_write`,
`thinking`, `cost_usd`). With the authoring agent's own spend, this is what a
merged change cost end to end. Dry runs post nothing.

`JERYU_BASE` names the forge origin and `JERYU_TOKEN_FILE` selects the approval
credential by path; both are required site settings with no default, since this
source is public. Set `REDTEAM_CLAUDE` to the site's pinned CLI executable and
`REDTEAM_CLAUDE_VERSION` to its exact version in `~/.config/pr-redteam/site.env`.
The reviewer and poke both read this file: poke computes the same review identity
and therefore needs the credential path and the exact CLI pin too. Installation
refuses to stage operational units unless all four settings are present. `REDTEAM_MERGE_TOKEN_FILE` selects the merger credential. API
calls require a bare `https://host` origin with no port, path, credentials or
query, an owned mode0600 nonsymlink regular token file and a valid bearer
value. The bearer travels through curl configuration
stdin, with curlrc disabled, and is absent from curl argv. This transport guard
is separate from model/process credential confinement.

A failed poke is separate `poke` heartbeat metadata with the unit's actual exit
timestamp. It preserves `last`, the last real review, and keeps the established
`redteam` label. A forge rejecting the optional field receives one retry without it.

Service failure notification is also site configuration. Set `NOTIFY_COMMAND`
in `~/.config/pr-redteam/site.env` to a shell command that receives the message
on stdin and can read the same bounded body from `PR_REDTEAM_NOTIFY_BODY_FILE`
or the retained `PR_REDTEAM_NOTIFY_BODY` environment variable,
or set `NOTIFY_WEBHOOK_URL` to receive a JSON POST. The body is capped by
`NOTIFY_MAX_BODY_BYTES` (default 8192) and omitted if it contains a configured
token value. Screening covers the full captured journal before truncation, for
the configured token files and named provider variables in plain, base64 and hex
forms, including whitespace-wrapped forms. It does not recognize every encoding
or credentials under other variable names; keep secrets out of journal output.
With neither configured, the notification unit logs that no target
exists and exits successfully. Hosts, channels and tokens do not belong in this
repository.

State lives in `REDTEAM_STATE` (default `~/.local/state/pr-redteam`). The per-PR
lock excludes concurrent reviews. Receipts record admitted attempts before model
execution; a killed worker leaves a visible pending claim. The next holder
archives it as interrupted before retrying. Terminal attempts remain under
`attempts/`, latest receipts under `receipts/`, and current work is removed when
an attempt terminates normally or recovers. Failed attempts never count as an
approval. Operators should investigate pending claims when no worker owns them.

### Review identity and reinstalls

Every receipt records `review_identity`, a sha256 over the review inputs: the
`review_format` constant in `pr-redteam`, `prompt.md`, `verdict.schema.json`,
`validate-verdict.jq`, the bytes of the `claude` CLI, the model, the CLI pin,
`REDTEAM_MAX_DIFF_BYTES`, `REDTEAM_MAX_BLOB_BYTES` and `REDTEAM_AUTHOR_DOMAINS`.
A head counts as already reviewed only when its receipt carries the current
identity (and the same base), so a review is reused only for the same review
inputs; any change to them re-reviews every open PR at its unchanged head.
`./pr-redteam identity` prints the current value.

The script's own bytes are not part of the identity. A release that only changes
plumbing (heartbeat, poke, merge pass, logging) keeps every receipt and does not
re-review unchanged heads. A change to the script that alters what the agent
sees or how its verdict becomes a decision -- diff, description or context
construction, the mechanical holds, the verdict-to-decision mapping, the
rendered review -- must bump `review_format` in the same commit.

`REDTEAM_ACCEPT_IDENTITIES` (space-separated, empty by default; set it in
`site.env` so the review pass and poke agree) lists earlier identities whose
receipts still count as already reviewed. It is for carrying receipts across a
release that only changed plumbing but moved the identity, such as the release
that took the script out of it. Read the live identity from any recent receipt
before reinstalling (`jq -r .review_identity <receipt>`), list it here, and
remove it once the heads it covers have moved on. Entries that are not 64
lowercase hex characters are logged and ignored. Only the "already reviewed"
decision reads this list; a new review always records the current identity.

## Before the first contribution

An installed reviewer runs the commit it was installed from. Until it is reinstalled (below) from a
commit carrying the contributed-origin gate above, it treats every pull request as internal and will
approve and merge whatever the forge hands it. Reinstall it under its owner's custody -- stop and
disable the units, install from this source, requalify the source/model/CLI -- and set the forge's
maintainer list before any contribution is imported.

## Installation and service ownership

`./install.sh` stages seven user units and reloads their definitions: review,
heartbeat and poke services with timers, plus the failure-notification template.
It refuses to replace active or enabled units, and refuses to stage the
operational units until their required site environment file exists. The existing
service owner must explicitly stop/disable an earlier installation, qualify the
selected source/model/CLI, and separately authorize activation. The script never
starts or enables a timer.

The units reference this source directory by absolute path. Treat any later
source update as a service change requiring its owner's custody and qualification.
The timer invokes a review pass and then a merge pass. `install.sh` enables no
unit. The merger credential's path comes from the site's
`~/.config/pr-redteam/merge.env`, read by review and scoped merge units; `install.sh` writes no
credential. Heartbeats report liveness through Jeryu's existing runner-reporting
allowlist and include the latest poke result, so a failed poke appears in the
runner's last activity on `/runners` and can be surfaced in Needs you. An
authorization refusal is logged, not bypassed. Installation also refuses to
replace the merge template while any of its instances is active. No scoped unit
is enabled or started by installation; activation belongs to the service owner.

## Review isolation

The pinned CLI runs from an empty directory with `--restricted --safe-mode`, an
explicit Read/Grep/Glob tool set and no MCP servers or customizations. Restricted
mode confines file tools to the empty working directory and exact PR review
archive. The model process receives only declared CLI authentication/runtime
variables; reviewer/merger paths and arbitrary service secrets are removed.
OAuth/provider authentication remains the existing service owner's responsibility.
The shipped unit contains no credential and no merger credential path: it only
reads the site's environment file.

Before a verdict can be printed, stored as a review receipt, or published, the
controller decodes its JSON strings and refuses the current reviewer bearer, the
configured merger bearer, and common encoded forms. Unsafe raw output is removed without echoing it. This is
an additional publication guard, not proof against every possible encoding or a
claim of OS-level isolation. Exact CLI behavior is owner-qualified before service
activation. A source merge does not establish sealed execution.

The CLI2.1.276 version/help readback confirms these flags; the official
[CLI reference](https://code.claude.com/docs/en/cli-reference) documents restricted
mode from2.1.248 and safe mode. PR text is still untrusted input to the model;
correctness/security qualification must include the actual model and host.

A queued head whose current entry failed or was dequeued may be retried once per failed base, with
at most three acknowledged retries per reviewed head. A new head has a new receipt. The controller
reads one bounded, paged `state=all` queue snapshot per merge pass, validates entry state/base SHA,
selects the newest entry for the exact repo/base/PR/head, and leaves building/landed entries alone.
Read errors or incomplete pagination are reported and defer retry. Reasons are bounded by characters
and control characters are collapsed before logging.

Observation and dry runs do not consume a retry. `queue_retry_bases` and the compatible
`queue_retried_base` marker are saved together with an accepted exact-head queue acknowledgement
or successful merge. Transient PR-detail, merge and queue errors leave the retry eligible on a later
pass. A refused queue request remains author work, as before. The native wire contract is
`QueueEntry`/`list_all` in jeryu-deploy `crates/jeryu-api/src/web/merge_queue.rs` (`base_sha`,
`enqueued_at`, `attempts[].at`, `reason`, and `page.has_more`); the fixture uses those actual fields.
