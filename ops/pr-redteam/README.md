# pr-redteam

Review pull requests on the forge named by `JERYU_BASE` at their exact head. Confirmed high or
critical security/correctness findings block. An explicit block verdict always
holds; failed processes, incomplete output and contradictory approvals publish
nothing. Findings and terminal attempt receipts remain available for review.

Where the base branch requires `jankurai/proof`, the quality gate comes first: a
head whose proof fails or failed to score is held with that reason before any
agent budget is spent, and nothing here can approve it. A proof the forge has
queued, is running, or has not started is not a verdict on the head: that head
waits for required contexts as described below. If that bounded wait expires, an
internal review can run while the proof is pending. Its validated model result is saved
atomically (one pending result per PR), bound to the review identity, the head,
diff base and origin, the PR row's stable fields (title, author, branches, draft,
state, labels, supersedes), the description, the signals and any upstream pin
evidence. The row's live fields (`updated_at`, `agents`, `checks`, `mergeable`,
`required_contexts`, `review`, the passport) are left out of that binding: they
move on every event, the proof finishing among them, and the gate is read live
before publication anyway. Until the proof has a result, later passes leave a
head with a computed result alone (no attempt, no agent). Once it has one, a pass
reuses the result if the binding still matches and it contains no
`pending_required_context` findings; those findings require a fresh model review
after proof reports. It publishes the result if the proof passed,
and deletes it; a proof that failed holds the head mechanically, as if it had
failed before the agent ran, and the result is discarded. A proof that turns red
while the agent runs is that same mechanical hold, never a neutral wait. The
review's cost is reported once, on the attempt that ran the agent, and the
published receipt carries it as `cost_usd`. `--force` bypasses reuse. Pending
receipts have `decision: waiting_gate` and never count as approvals. Contributions retain their existing admission rule
because they have a one-attempt spend cap. Repositories
outside the gate's rollout are unaffected — their proof is reported, not
required. `ops/ci/jankurai-gate.sh` is the same verdict, run locally before the
pull request exists.

## Opt-in held-review handoff

Held-review filing is disabled by default (`REDTEAM_FIX_TODO=0`). A service owner
must qualify the Todoq executable and explicitly select automation author logins
with `REDTEAM_FIX_TODO_AUTHORS` before enabling it. Unknown authors remain with
their author. Drafts, contributions, selected humans with recent activity,
approvals and holds without high or critical findings create no work. A held head
gets no grace period by default, so the next filing pass dispatches immediately.
`REDTEAM_FIX_TODO_GRACE_SECS` can explicitly restore a delay for an author push.

An enabled pass attempts at most `REDTEAM_FIX_TODO_MAX_PER_PASS` new filings
(default one, maximum nine). It uses the verified Todoq `add` contract with
explicit family, repos, title and priority, plus `--no-triage`; findings do not
enter an extra triage model call. The ask contains bounded high/critical findings
as fenced JSON data and says they are untrusted evidence, never instructions.
The canonical task link comes from the forge's PR read, with an additional
live head check before dispatch intent is recorded. Unavailable metadata, a moved
head or a link outside the configured forge defers filing without consuming it.
It requires the worker to authenticate the still-open PR and original head before
editing or publishing, follow repository instructions, and use its own worktree.
The handoff requires new commits on the original PR branch, a passing
`ops/ci/pr-ci.sh`, and a normal fast-forward push after rechecking the exact head
and branch. It forbids replacement PRs, rebases and force pushes. This is a worker
requirement in the dispatched ask; it does not add a branch-publication mode to
Todoq or install or activate a worker.

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

## Two holds, then a person

What holds a head does not change: a confirmed high or critical finding still holds it. What changes
is how often the agent is asked. An author who answers each hold with another push gets every push
fully re-reviewed, and often held again. After `REDTEAM_HOLD_CAP` agent holds on one pull request
(default 2, across its heads; `0` turns the cap off), its later heads get no agent review:

- The mechanical holds still run and still hold: the quality gate, a committed private key, an
  unpinned blob. They do not count toward the cap. A proof that was pending when the attempt
  started and failed during it is the quality gate's hold (`hold_kind: gate`), with or without
  the agent.
- A head none of them holds gets a blocking (request-changes) review that names the cap, a final
  `capped` receipt and one `pr.skipped` event on the PR's timeline. Nothing capped is approved or
  merged. Inside pr-redteam the cap's stand-in verdict is `block`, so a head the agent never read
  fails closed. On the forge, the blocking review rests on how jeryu-core decides a head's
  reviews (`branch_protection/reviews.rs`, `reduce_reviews`, and `evaluate.rs`): each reviewer's
  newest verdict on the exact head counts, a dismissal withdraws a verdict only when its own author
  files it (another reviewer's or an admin's dismissal withdraws nothing), and a counted
  `changes_requested` is an intrinsic merge blocker that binds admins whatever the branch
  protection. So a person's approval alone cannot land a head the agent never reviewed, and this
  reviewer's own later approval of that head replaces its request for changes.
  If posting the review fails, the next pass posts it again.
  A review-identity change (a model, prompt or limit change) does not post it twice: the review
  already posted on that exact head stands, and only the receipt is renewed.
- What the cap trades is the agent's spend for a person's attention and the author's wait: a
  capped head is not read by the agent until a maintainer rearms the PR, and it can land only
  after that rearm and an agent approval of that exact head. Two cheap holds buy the author a
  wait for a person, never an unreviewed merge. A capped head files no held-fix todo (`REDTEAM_FIX_TODO`): it is parked for a
  person, and an agent fix would be one more push the agent does not review.
- The review footer says where a PR stands (`hold 1 of 2`, then `hold 2 of 2: this PR is now left
  for a person`).
- `./pr-redteam rearm owner/name N` lets the agent review the next head and starts the count again;
  an operator's `run --force` reviews a capped head once.

Only holds recorded with `hold_kind: "agent"` count, so holds from before the cap existed never
park a pull request on install. The cap changes the posted review (its footer) and adds the
`capped` decision, so it bumps `review_format`: every open pull request is reviewed once more
after installing it.

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

### A queue refusal is filed as rework, not left for a person

The queue refuses an enqueue it cannot replay onto the base tip
(`queue_conflict`, `queue_mismatch`, `queue_merge_commits`), and preparing the
replacement pull request then waited for a person: 22 of 186 queue entries were
refused between 2026-09-19 and 10-15. With the held-review handoff enabled, such
a refusal instead files one `now`, p1 rework task through the same qualified
Todoq executable, author selection (`REDTEAM_FIX_TODO_AUTHORS`), family and
durable ledger, and `REDTEAM_QUEUE_REWORK=0` turns this one off while leaving
the held-review handoff on. The ask carries the pull request, its original head
and branch, the base tip the replay was refused against and the conflicting
paths — read back from the refusal the forge stored, as data, inside the same
bounded untrusted-evidence fence. It asks for a cherry-pick onto that base tip
in an isolated worktree, a local run of the repository's required gate, a
replacement pull request, and a comment on and closure of the original. It
forbids resolving by `-X ours`/`-X theirs`, force-pushing or rewriting either
branch, and merging, enqueueing or approving the replacement: the replacement
goes through the gate and this review like any other pull request, and nothing
is landed here.

A refusal the forge did not store, a refusal carrying no base commit, a head
that moved, an unavailable canonical link, and `queue_conflict_queued` — a head
that conflicts only with an entry queued ahead of it and is simply queued again
later — all file nothing. The ledger is `queue-rework/<repo>/<PR>-<head>.json`
under `REDTEAM_STATE` and is written before dispatch, so a refused head files at
most one task, and an uncertain outcome is retained for the owner to reconcile
rather than retried. `test/queue-rework.sh` holds all of this.

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

Independently of that setting and in every repository, a head any of whose
commits is authored or committed by git's own placeholder identity (`Your Name`,
`you@example.com`) is held once per head with a `placeholder_author` receipt,
before any agent budget is spent. The provenance of the exact commit a
maintainer approves has to be readable from the log, and an unconfigured git
writes a name that says nothing. This decides only whether a head is reviewed,
so it does not move `review_format`: a head already reviewed keeps its receipt.

## Lock-source report

`signals.txt` carries a lock-source section from `lock-source-report`, a shell wrapper that runs `python3 -I`. The
changed-file list is read NUL-delimited (`files.nul`), so no path is parsed from git's quoted form.
Each changed `Cargo.lock` is read at the base and at the head and parsed with the standard library's
TOML parser (no awk, grep or sed reads TOML). The `[[package]]` entries (name, version, source,
checksum, replace) and the `[patch]`, `[replace]` and `[metadata]` tables are compared as sets and
reported as ADDED, REMOVED or CHANGED. An added or deleted lock file is moved and is reported per file.
A lock that is missing at both revisions, fails to parse (a repeated key included), or is over a limit
(8 MiB, 20000 entries, 50 files) is NOT ANALYSED, and the summary never says nothing moved while any
lock is. Every value is printed as a JSON string. Stated limit: dependency edges are not compared.
Suite: `test/lock-source.sh`.

## Upstream evidence for a git-pin bump

When a change moves a git dependency's revision (a `rev =` in Cargo.toml, inline or in a
`[dependencies.<name>]` table, a `source = "git+...#rev"` line in Cargo.lock, or a row of a
repository's `hosted-pin-refs.tsv`), the review directory gets `upstream/`: `SUMMARY.txt` and, per
fetched pin, `pin.json`, `log.txt`, `diff.patch` (the crates the dependent names), `pulls.json` (each
commit's pull request, merge state and branch) and `note.txt`.

A pin **already reviewed upstream** gets no `diff.patch`, only `diffstat.txt`. Every one of these must hold:
the pin is verified (below) on a branch the forge reports protected; it moves forward; its commit
list, log and pull requests were read whole; and every commit in the range is in the diff of a pull
request merged into that branch that this same reviewer identity approved (effective, not stale) at
that pull request's exact head -- its commits taken as the review diff takes them,
`rev-list head ^merge-base(base_sha, head)`. A commit pushed straight to the branch, or landed by a
squash or merge commit, is in no such range and keeps the diff. `pin.json` `commit_pulls` and
`approved_pulls` record the attribution; the SUMMARY row says the diff was not fetched.

A merge queue replays an approved head onto the branch tip, so what lands are new commits, not the
head that was approved. Such a landing counts for its pull request only when it is that pull
request's commits replayed with **exactly** the reviewed content. When some commits of a pin are
still unattributed after the rule above, the GitHub-shaped closed listing (`GET
/api/v3/repos/<owner>/<repo>/pulls?state=closed`) is read for that pin, because only it carries
`merge_commit_sha`, the commit where the forge says each landing ends. It is read newest first until
an empty page, up to `REDTEAM_UPSTREAM_MAX_PULL_PAGES`; a cap reached before every unattributed
landing was found is noted. The landing is the run of first-parent commits after the previous
landing end (a landing commit, a commit attributed above, or the old pin) up to the recorded one. It
must have as many commits as the pull request's own review diff. For each pair in order, landing
commit L and the pull request commit C it replays, a clean three-way replay of C onto L's parent
(`git merge-tree --write-tree --merge-base=C^ L^ C`, git 2.40 or later) must write a tree **identical**
to L's: the same tree id, so every file byte for byte, whitespace included. Context that moved under
the replay is tolerated because the merge places it, not a textual patch; anything else on L is not.
Neither commit may be empty, a root or a merge; a conflict or any git failure fails closed. The
author, author date and message must match as well, but metadata alone proves nothing, since anybody
can copy it. A direct push between two landings lengthens the run and a squash shortens it. Altered,
re-indented, extra or dropped content under copied metadata, a reordered replay, an empty commit, a
reworded replay, a merge commit, a conflicting replay, a landing that began before the old pin, a
missing `merge_commit_sha`, an unreadable listing and anything after the last landing end all keep
the diff. `pin.json` `landing_pulls` records each landing considered, the method per commit
(`replay_tree`) and why any was not attributed (`test/queue-landing.sh`).

The packet shows what the attribution used. `pulls.json` carries every pull request that
`commit_pulls`, `approved_pulls` or `landing_pulls` names, with its number, head sha, base ref, merged
state, landing commit (`merge_sha`) and the head this reviewer's approval is on (`approval_head`); a
landing read from the closed listing is marked `source: "closed-listing"`. `pulls.commits_without_pull`
and note.txt count the range's commits attributed to no pull request in `pulls.json`. If that evidence
cannot be written within its budget, or a named pull request is missing from it, the attribution is
withdrawn: `already_reviewed_upstream` is false, the diff is fetched, and `pin.json` names only pull
requests `pulls.json` shows. That code went through those pull requests,
so the reviewer does not read it again or hold the pin over its design (jain-deploy#107 held three
times doing so). `pin.json` records `already_reviewed_upstream` and whether `diff.fetched`. Any
other pin keeps its diff.

The manifest is the author's text, so it never decides what is fetched or what counts as verified:

- Only a dependency already pinned at the PR's base -- the same file, dependency name and repository
  -- is fetched. A brand-new pin is reported as `new-pin-unverified` and nothing is fetched.
- Only the forge named by `JERYU_BASE` is fetched from. A source on another host (a GitHub mirror)
  counts only through an `insteadOf` mapping to this forge that the base's `.cargo/hosted-gitconfig`
  already carries; otherwise it is `unmapped-host` and nothing is fetched. `REDTEAM_FORGE_ALIASES`
  (operator environment only, never the PR or its base) lists other hostnames that are this same
  forge: their `/git/<owner>/<repo>.git` URLs count as forge repositories and are still fetched from
  `JERYU_BASE`, with the same pin, protected-branch and approval checks.
- A source that moved from an old host (a GitHub mirror) to this forge is bound by
  `REDTEAM_SOURCE_MAPPINGS` (operator environment only, empty by default): space-separated
  `<https url>=<owner>/<name>` entries, each one exact source URL (no host is aliased). The base's
  pin on that URL is then the same dependency as the forge repository, provided the head names
  the forge directly (or a configured forge alias). This applies only from the old source to the
  forge; moving a pin onto the mapped external URL remains unverified. The evidence summary names
  the old source, operator mapping and head source, including a move that keeps the same revision.
  The move gets the full diff, exact revision/tag, protected-branch and approval checks. Activating an entry is a
  separate, operator-authorised act; a dependency absent from the base stays `new-pin-unverified`,
  and nothing a PR or its base writes can add an entry. A conflicting Git rewrite from the base
  cannot override an operator entry. Malformed entries are ignored.
  Owner-decision context for the independent review comes from an approval by the namespace owner
  or a `REDTEAM_OWNER_DECISION_AUTHORS` login on the exact head (see above), never the PR author.
- Fetches run with no system, global or XDG git configuration, no ambient credential helper and no
  netrc, and present only the reviewer's own credential.
- The forge, not the manifest, says which branches count: the repository's default branch and the
  branches it reports protected. A branch the change names (Cargo `branch`, `?branch=`, or the TSV's
  support ref) counts only when the forge protects it. `pin.json` records the branch checked, its kind
  and whether the change named it, the tip and when it was fetched. `pin.json` is written only once
  the new rev resolves.
- Parallel reviews share an upstream's object cache, never its tips: a review fetches into refs of
  its own (`refs/up/<pid>/`), cleared before the fetch, and fetches, reads tips and decides the
  status under one lock, deleting its refs before releasing it.
- The reviewer's credential is offered through a helper scoped to the forge's host that answers
  only for that host. Upstream commit messages, pull request titles and diffs are untrusted text,
  like the PR's own.

Only `merged-tip` and `ancestor-of-tip` are verified. `on-unprotected-branch`, `NOT-ON-BRANCH`,
`branches-unknown`, `rev-not-on-forge`, `new-pin-unverified` and `unmapped-host` are unverified;
`SUMMARY.txt` and `prompt.md` say what each proves. Upstream evidence shares the diff's size limit: the
total across all pins is at most `REDTEAM_UPSTREAM_MAX_BYTES` (default 400000), a quarter of
`REDTEAM_MAX_DIFF_BYTES`, and what the diff leaves of that limit; a pin whose share is under 1024
bytes is not fetched. `REDTEAM_UPSTREAM_MAX_PINS`,
`_MAX_COMMITS`, `_MAX_BRANCHES`, `_MAX_PULL_PAGES` and `_FETCH_TIMEOUT` bound the rest. Every cut (bytes,
commits, pull request pages, pins, protected branches) is noted in `SUMMARY.txt` and `pin.json`, as is
a pin that moves backwards.

### Release lock entries

A release lock is a TOML file at the repository root named `*.lock.toml` that holds one `[[repo]]`
table per pinned repository:

```toml
[[repo]]
repo = "web"
tag = "web-v1.2.0"
commit = "<40-hex commit>"
web_dist_sha256 = "<hash of the built bundle>"
github = "https://github.com/example/web.git"
required_check = "web/required"
```

A change that moves an entry's `commit` or `tag` gets the same `upstream/` evidence as a git pin, by
the same rules: only an entry the base already has (same file, same `repo =` name) is fetched, and a
new entry is `new-pin-unverified`. The repository fetched is `<the dependent repository's
owner>/<repo>` on this forge, and only once the forge says it exists; otherwise the entry is
`repo-not-on-forge` and nothing is fetched. URL fields such as `github` are never fetch targets. A
`commit` that is not 40 hex (`PENDING`) is not fetched; at the base it simply means no old rev.

For a lock entry, `upstream/` adds `diffstat.txt` (the whole repository's diff stat; `diff.patch`
covers the whole repository within the cap), and `pin.json` adds `lock_entry`, `tag`, `old_tag`,
`tag_resolves_to` (what the forge's `refs/tags/<tag>` peels to), `tag_matches_commit`,
`tag_annotated` and `branch_status`. **Verified** for a lock entry means both: the commit is
`merged-tip` or `ancestor-of-tip` on a default or protected branch, AND the forge's tag peels to that
commit. A tag that peels elsewhere, or that the forge does not have, is `tag-mismatch`, which is
unverified whatever `branch_status` says. A lightweight tag that peels to the commit verifies, and is
recorded with `tag_annotated: false`. The entry's other fields (`locked_fields`, such as
`web_dist_sha256`) are recorded with their base values as "author-measured, not reproduced by the
reviewer": the reviewer builds nothing.

A table with no `repo =` key is named by its `name =` key instead (the `jeryu-split.lock.toml`
shape). Location fields (`github`, `jeryu`, `github_slug`, `local_path`) are never fetch targets and
are not recorded as locked fields. An entry that names no `tag` at the base **or** at the head -- a
repository pinned by commit alone -- has no tag to cross-check: it is judged by its commit, exactly as
a git rev pin is, and `pin.json` records `untagged: true`. An entry whose tag the change removes is
not untagged; its tag is missing, which is `tag-mismatch`.

### Every PR waits for its required contexts

While any context enforced by the base branch has no result (missing, pending, queued or running),
review waits: no receipt, review, check run or agent spend. The log says `waiting for required
contexts`. A later pass reviews the head once all required contexts have results; failures are
results too. `REDTEAM_GATE_WAIT_SECS` bounds the wait (default 5400 seconds, or 90 minutes) from
that head's first observation. After expiry the review proceeds with the unresolved states in
`signals.txt`. Force and dry-run obey this admission check too; neither starts an agent
inside the bound. The operator escape is `REDTEAM_GATE_WAIT_SECS=0` for ordinary heads
(and `REDTEAM_PIN_WAIT_SECS=0` for release-pin heads). This disables admission delay,
not the proof publication gate or branch protection. A zero-bound signal says the wait
is disabled, rather than claiming the head waited out a timeout.

Release pin bumps use this same path with their existing `REDTEAM_PIN_WAIT_SECS` override (default
3600 seconds, `0` disables the pin wait). Only the forge's complete exact-head diff can classify a
change as release pins only (root `*.lock.toml` or `hosted-pin-refs.tsv`). Other changes and unknown
diffs use the general bound. An unavailable diff is retried without resetting the clock. The
existing `$REDTEAM_STATE/pin-wait/` records are retained across reinstalls for both kinds of head.

A missing result alone must not consume the two-hold cap. The reviewer marks each finding solely
about such a result with `pending_required_context`, naming the exact context. A block containing
only those findings is recorded as a gate hold only when the forge confirms every named context
is enforced and missing/pending. Mixed code findings, failed or unknown contexts, and unreadable
protection keep normal agent accounting. No prose matching or review dismissal is involved: the
blocking review still stands, and the forge still requires all gates before landing.

The classifier examines only model findings, before controller findings are appended.
We deliberately retain all-or-nothing accounting: even a low-severity unlabelled model
finding keeps a mixed block counted. Splitting findings into separate decisions could
hide why the model blocked; no finding or blocking review is removed. The footer calls
a missing-only model block a required-context hold, rather than a mechanical hold.
A lane that never reports eventually reaches admission expiry and can receive such a
blocking review without exhausting the cap; expiry does not manufacture a passing result.

Proof publication remains separate: after admission expires, a pending `jankurai/proof`
allows computation but saves the result without publishing. A subsequent pass with proof
still pending leaves it alone. Before reuse, any cached result containing a
`pending_required_context` finding is recomputed, even if the named context is still
pending; the log describes recomputation, not a claim that proof has reported. A failing
proof discards the result and holds mechanically. A passing proof permits reuse only
when the existing input key matches and no such findings need recomputation.

### The enforced required contexts

Which contexts a head must satisfy is the forge's branch protection for its exact base branch, read
from `GET /api/v3/repos/<owner>/<name>/branches/<base branch>/protection`
(`required_status_checks.contexts`), once per branch per pass. Only a repository administrator
changes that list: `main` enforces `<repo>/required`, and a release line enforces whatever its own
protection lists -- `<repo>/fast` only once an administrator has made it so, and its previous
contexts until then (jeryu-deploy ADR 0019). Every review's `signals.txt` lists exactly those
contexts, each with the state the forge reported for it on this head, or `no result` when the head
has none; the review judges gate evidence against that set and nothing else. A context the pull
request row reports that protection does not enforce satisfies no requirement, and no context is
derived from a repository name, a branch name, the PR's own files or a record -- there is no release
exception. A branch the forge reports as unprotected enforces nothing, and a protection read the
forge will not answer leaves gate evidence unresolved: `signals.txt` says so, the enforced set is
treated as unknown rather than empty, and the bounded wait still waits for what the row reported.
If that row also reports no contexts, there is nothing identifiable to wait for: review
starts immediately with the unresolved-protection warning. This does not prove there are
no requirements and cannot exempt a model block from the hold cap.
Pin verifiers are independent of all of this: a green required context never substitutes
release-line ancestry for a verifier's required ancestry on `main`.

## Qualification

`bash test/required.sh` runs offline quality-gate, draft-skip, review-identity, verdict, binary-payload,
upstream-evidence, credential-transport, heartbeat contract, poke, watch, publication/recovery, merge-pass, queue-rework, contributed-origin, owner-decision and installation checks. The actual repository required lane
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
./pr-redteam watch --dry-run --once
./pr-redteam rearm acme/widget-web 16
```

`run` reviews, then lands what it approved, then performs the disabled-by-default
held-review handoff when the service owner has enabled it. `heartbeat` sends one
beat per reviewer slot: a review takes a numbered slot for
as long as it runs, so `/runners` shows `REDTEAM_JOBS` rows (`<id>`, `<id>-2` …)
instead of one row for the whole pass. Each beat follows the forge's runner contract, which refuses a
beat with any field it does not define: `current` and `last` are cut down to
that contract's fields before sending, and a receipt decision the forge has no
reviewer conclusion for (`base_missing`, `author_domain`, `placeholder_author`, `advice`, `capped`) is sent as
`hold` with the decision in `reason`. A beat also names the code it runs,
`code: {repo, commit}`: the commit comes from `source-commit`, which
`git archive` fills in (`export-subst`), or from a git checkout of this
repository whose `ops/pr-redteam` is unmodified; otherwise `code` is left out. `tools` lists the
`claude` CLI version the last review measured, and is left out before the
first review. `poke` runs every 30 seconds from
`pr-redteam-poke.timer`. Unreviewed heads start `pr-redteam.service` early. A
head's `review` poke is usually used up while its required gate is still
running. Such a head, still open and ready, with no receipt or a `waiting_gate`
receipt, gets
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

`watch` is the event-driven trigger, and `pr-redteam-watch.service` is the unit
that runs it. It long-polls `GET /api/v1/review-wanted?after=<seq>&wait=<secs>`,
the forge's record of the pull request heads that became reviewable: one signal
per pull request opened and per open pull request whose head a push moved
(jeryu-deploy `docs/repo-automation.md`). The forge holds the request open until
a head appears, so a push reaches an idle reviewer slot in about as long as the
push took, while its gate is still running. Each reported head queues and then
starts `pr-redteam-review@owner:repo:PR:head.service`, at most `REDTEAM_JOBS` at
a time, so one long review delays no other head; the rest wait for a free slot
and are started by a later poll. A running review counts against that bound in
every unfinished systemd state (a running oneshot instance is `activating`, not
`active`). A head only leaves the queue once its unit
started, the queue is bounded, and the cursor advances only over heads that are
on disk, so a crash repeats a signal (which the per-PR review lock and the
receipt make a no-op) rather than losing one.

A signal only says a head appeared. The scoped review reads the pull request
itself and applies every rule a pass applies -- the draft and author skips, the
hold cap, the contribution budgets, the quality gate and publication -- and it
reviews the pull request's live head, so a head pushed after the signal is
reviewed as itself. It first checks coverage the way a pass does: a repository
the forge does not list for the reviewer, or one outside `REDTEAM_FAMILIES`, is
skipped, neither reviewed nor approved. Neither the watcher nor a scoped review carries the merger
environment: nothing is landed from this path, and an approval still requires
the base branch's required contexts to be green before the merge pass lands it.
A forge that answers anything else, a forge whose sequence went backwards (a
restart) and a watcher that was down all cost today's latency and nothing else:
the five-minute pass and the 30-second poke remain the fallback. The watcher
does not rely on the forge to pace it: an answer that comes back in under two
seconds with nothing new waits out the rest, and a failed poll backs off from
5 seconds, doubling to at most 5 minutes.

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
`REDTEAM_MAX_DIFF_BYTES`, `REDTEAM_MAX_BLOB_BYTES`, `REDTEAM_AUTHOR_DOMAINS`,
`REDTEAM_OWNER_DECISION_AUTHORS` and the `REDTEAM_UPSTREAM_*` limits.
A head counts as already reviewed only when its receipt carries the current
identity (and the same base), so a review is reused only for the same review
inputs; any change to them re-reviews every open PR at its unchanged head.
`./pr-redteam identity` prints the current value.

Nothing about the installation is part of the identity: not the script's own
bytes, not the commit it was exported from, and not where the install puts its
files or the CLI. A release that only changes plumbing (heartbeat, poke, merge
pass, logging) keeps every receipt, so reinstalling it -- a new export in a new
directory, from a new commit, even with the CLI moved -- re-reviews nothing and
leaves every posted approval valid. A change to the script that alters what the
agent sees or how its verdict becomes a decision -- diff, description or context
construction, the mechanical holds, the verdict-to-decision mapping, the
rendered review -- must bump `review_format` in the same commit.
`test/review-identity.sh` holds this: a reinstall with an unchanged prompt,
schema and model keeps an approved head approved and queues nothing.

`REDTEAM_ACCEPT_IDENTITIES` (space-separated, empty by default; set it in
`site.env` so the review pass and poke agree) lists earlier identities whose
receipts still count as already reviewed. It is for carrying receipts across a
release that only changed plumbing but moved the identity, such as the release
that took the script out of it. Read the live identity from any recent receipt
before reinstalling (`jq -r .review_identity <receipt>`), list it here, and
remove it once the heads it covers have moved on. Entries that are not 64
lowercase hex characters are logged and ignored. Only the "already reviewed"
decision reads this list; a new review always records the current identity.
Receipts from before the CLI's path was taken out of the identity are reused
without being listed, for the same inputs.

When a change does move the identity, the wave of re-reviews it queues is the
operator's to pace: `REDTEAM_FAMILIES` narrows a pass to named forge families
("all", the default, covers every repository including those with no family),
and `REDTEAM_PRIORITY_FAMILIES` reviews the named families first and makes the
rest wait for a pass where those have nothing left. Setting `REDTEAM_FAMILIES`
to one family in `site.env` spends on that family only; widening it later
reviews the rest at whatever head they then have, rather than paying for every
open PR in the family at once. Set both in `site.env`, so the review pass and
poke agree.

## Before the first contribution

An installed reviewer runs the commit it was installed from. Until it is reinstalled (below) from a
commit carrying the contributed-origin gate above, it treats every pull request as internal and will
approve and merge whatever the forge hands it. Reinstall it under its owner's custody -- stop and
disable the units, install from this source, requalify the source/model/CLI -- and set the forge's
maintainer list before any contribution is imported.

## Installation and service ownership

`./install.sh` stages nine user units and reloads their definitions: review,
heartbeat and poke services with timers, the event-driven watcher and the scoped
review template, plus the failure-notification template.
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
replace the merge or scoped-review template while any of its instances is
running (systemd's `active`, `activating`, `deactivating` or `reloading`; a
running oneshot instance is `activating`). No scoped unit
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

### This integration's receipt boundary

This source also integrates the owner-context and progress behavior from #78.
It is a semantic controller change: predecessor review identities must not be
accepted for this upgrade. `REDTEAM_ACCEPT_IDENTITIES` is only appropriate for
a separately documented plumbing-equivalent reinstall. It stays unset for
this integration; new receipts use the current input identity.

`family.lock` at the repository root is also a release lock. Release locks are
parsed with isolated Python `tomllib`, with byte and entry limits. Invalid or
unsupported input produces `NOT ANALYSED` in the upstream summary, never a claim
that no pins moved. Repository names resolve under the dependent owner on the
configured forge; lock URLs and local paths cannot select a fetch target.
New family members get forge ancestry/tag evidence and a bounded full-tree diff,
without claiming independent review coverage: a release composition's new member
is source the dependent ships, so `family.lock` fetches a `[[repo]]` the change
introduces instead of reporting it `new-pin-unverified`, as a `*.lock.toml`
entry new at the head still is. Unchanged commit/tag pairs are omitted. The
existing pin and byte budgets still apply: a fourteen-pin release can exceed the
pin limit, and the summary reports how many were not fetched. More changed
manifests than `upstream_pins` reads is also `NOT ANALYSED`, for the whole
change rather than for the manifests past the limit.
