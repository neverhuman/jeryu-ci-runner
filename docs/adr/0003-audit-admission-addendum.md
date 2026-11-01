# ADR 0003 addendum: forge-ticket audit admission

Status: Accepted (implementation; live host probe remains an owner step)
Date: 2026-10-21

This adds to jeryu-deploy's
[ADR 0003](https://git.jeryu.ai/jeryu/jeryu-deploy/blob/main/docs/adr/0003-gating-runs-on-a-dedicated-gate-host.md)
and uses its ADR 0011 bound audit-ticket contract (continued by ADR 0012).

A served repository's bound ticket admits its exact head regardless of which
clone or agent pushed it. Admission does not require local clone discovery or
an internal pull-request label lookup. Repository scope, validated ticket
fields, main ancestry of metadata, policy digest, assigned auditor verification
and the forge's authenticated publication checks remain required. Submission
retains the job ID, head, base, metadata and auditor binding; a newer push
cannot inherit proof from an earlier head.

A contributed ticket, including `contrib/gh-<n>`, requires the configured
`PR_GATE_SANDBOX_COMMAND`. Claims advertise `sandbox: true` only when that
command resolves on `PR_GATE_SANDBOX_PATH`; otherwise contributions remain
waiting for a sandbox, and any delivered contribution is handed back. The
existing recipe sandbox contract is reused: command, disposable tree root,
repository directory, then argv. The adapter must mount only that root at its
existing path in an ephemeral, network-restricted container or VM, enter the
repository, and execute argv. It must provide the assigned binary's runtime.
Command availability is configuration readiness, not a live isolation probe.

The host fetches using its credential helper, prepares trusted metadata and
copies the verified assigned auditor beside the source. Only that disposable
tree enters the sandbox. The adapter receives an empty environment plus the
explicit sandbox path, locale and marker; the auditor receives Git settings
that disable credentials and global/system configuration. Authentication
files, host tools, caches and home are outside the mounted tree. The audit
lock descriptor is closed. A sandbox failure never retries on the host and
never reuses an earlier report. Publication remains on the authenticated host.

The contributed gate path from todo a023e8 is present (commit 87d40d7), as is
the contributed review policy from 89123b (c5929cb). This adds audit execution
to the former's sandbox interface; it does not change recipe ok-to-test or
maintainer merge approval. Older forges without bound tickets keep their
existing internal-PR admission behavior, since those tickets lack trusted
origin and auditor assignments.

`ops/pr-gate/tests/test-pr-gate-audit.sh` proves the claim, clean sandbox
handoff, trusted policy, exact-head publication, personal-agent admission and
failure behavior using a fixture forge and local Git repositories. Its adapter
is a contract fixture, not evidence of operating-system isolation. A live
probe on the dedicated gate host remains a separate owner/lead operation;
this change performs no live PR or network probe.

Merge-queue audit tickets have a stricter admission rule under either contract:
the live building entry must match the ticket's repository, ref, number and head. Every building source in the stack must be an open internal
PR at its recorded source head; the bottom replay base must be a valid commit
on the clone's own main before checkout. The diff audit base must be an
ancestor of that bottom, and the bottom an ancestor of the queue head, so the
range covers the whole stack (the forge uses its fork with main). A missing/non-building queue ancestor
is accepted only once its commit is on main. Bound queue jobs additionally
require authoritative `origin: internal`. Queue contributions are handed back
even on sandbox-ready hosts; enabling contributed queue audits requires a
separate reviewed extension of this stack admission and sandbox contract.

### Merge-queue replay contract and content binding

The deployed forge at `60da213c7cd1eb8d1459e5b1ceda252616b5de9d`
implements the queue in jeryu-deploy's
[`web/merge_queue.rs`](https://git.jeryu.ai/jeryu/jeryu-deploy/blob/60da213c7cd1eb8d1459e5b1ceda252616b5de9d/crates/jeryu-api/src/web/merge_queue.rs).
Its `build_on` calls `git.replay(parent, &entry.pr_head_sha, ...)` and then
assigns `entry.base_sha = parent.to_string()`. Enqueue selects the last
building entry on the same base, records `entry.after = Some(number)` and
passes that entry's queue SHA as `parent`; only the first entry uses the
base-branch tip. A **refused** replay separately records the branch tip for
conflict repair. The redteam conflict-repair instructions and the scheduler
IR are not the contract for building web queue entries.

A read-only live response on 2026-11-01 confirmed the same contract:
root/jankurai #29 was building at
`971485147b79db61fe4ee3202f1f58cba2ab6e78`, while #22 had `after: 29`,
`base_sha: 971485147b79db61fe4ee3202f1f58cba2ab6e78` and queue SHA
`b9d5e05d34b87c491941f309d42b0099b32d32ff`.
The authoritative producer contract is that deployed `build_on` implementation.
The complete response, including the paging envelope, is recorded in
`ops/pr-gate/tests/fixtures/merge-queue-60da213.json` (capture details beside
it). The contract regression asserts the recorded replay-parent relation and
runs the production consumer against its envelope with local object identities.
This response corroborates field semantics; it is not a successful live audit.

The fixture builds independent PR heads before main advances and cherry-picks
them onto main and the previous queue replay, respectively. In addition to
checking the authenticated mapping, admission independently compares each
fetched queue tree with `git merge-tree --write-tree --merge-base=<fork>
<parent> <source>` before checkout. Conflicts, extra queue bytes, missing
source objects and ambiguous entries fail closed. A response that substitutes
the branch tip for a stacked replay parent cannot hide another contribution:
the expected tree excludes those undeclared changes and the comparison fails.
The replay verifier requires Git >= 2.40 for `merge-tree --merge-base` and
checks the version before reconstructing any queue tree. An unsupported or
unreadable version is reported as a **tool-version error**, never a tree
mismatch. Bound jobs are immediately released with the existing
`verifier-mismatch` reason and the explicit Git diagnostic on `/runners`.
This checks resulting content rather than trusting that source commits occur
in replay ancestry. It may refuse a complex replay whose sequential
cherry-picks differ from the resulting three-way merge; such a case needs a
separate reviewed extension, never an unchecked checkout.

This implementation admits queue stacks rooted on main only. Other protected
release-line queue bases remain unsupported and fail closed. Only canonical
`refs/queue/...` ticket refs select queue admission; an ordinary PR branch
named `queue/main/3` retains ordinary admission. Bound refusals immediately
release with existing ADR 0011 reasons: `malformed-ticket` for unusable queue
mapping, fetch, range or replay content, `not-on-main` for an untrusted stack
bottom, and `contributed` for contribution origin. No new release vocabulary
is introduced.

### Which forge code the queue contract comes from

The protected implementation is authoritative for all three couplings, in
jeryu-deploy at `60da213c7cd1eb8d1459e5b1ceda252616b5de9d`
(this installation's forge serves it at `https://git.jeryu.ai/jeryu/jeryu-deploy`):

- The listing this host reads is registered in `crates/jeryu-api/src/web.rs`
  as `("/api/v1/repos/:id/merge-queue", get(merge_queue::list_repo))`; it lists
  one repository's entries in every state and answers `{entries, total, page}`.
  Its query reads `limit`, `per_page` and `page` only (`QueuePageQuery::KEYS`),
  and `web/strict_query.rs` refuses any other key with `invalid_query` at 422.
  The global `/api/v1/merge-queue` (`list_all`) is a separate, state-filtered
  contract and is not read for a repository-scoped admission.
- `merge_queue.rs::build_on` records the replay parent in `base_sha`.
- `ci_bridge/audit_queue.rs::plan_push_audit` tickets a queue head against
  `merge-base refs/heads/<base> <queue sha>`, which is why admission requires
  the diff base to be an ancestor of the stack bottom: that fork is the bottom's
  replay base whenever the stack is rooted on the base branch, and stays so
  after the branch tip moves on.

`ops/pr-gate/tests/test-pr-gate-audit.sh` exercises each one against a fixture
forge shaped like that route: strict query keys, the recorded paging envelope
split one entry per page so a multi-entry stack is assembled only by following
`page.has_more`, and a dispatched base computed with the forge's own
`merge-base` expression while `main` is ahead of the stack. A listing the route
refuses (422) releases the ticket before any checkout; a transient failure (503)
leaves it claimable after its lease expires, also without checkout. This is
consumer contract evidence, not a live governed audit.

### Forge link verification

Documentation links here use `git.jeryu.ai`, the web origin advertised by
both deployment aliases in `GET /api/v1/repos?limit=100` on 2026-11-01.
`git.neverhuman.org` also resolves these files; it remains this runner's
canonical Git transport host (see the repository README). This web-link choice
does not change dependency URLs or Git transport policy.

Read-only HTTPS checks returned 200 for both linked `/blob/` paths on both
hosts. Because those responses contain the web app shell, file identity was
also checked through `GET /api/v1/repos/<id>/raw?ref=<ref>&path=<path>` on
each host. Both repository listings identified `jeryu/jeryu-deploy` as
`83e8174f-e3e5-437d-a7ce-dd789c0d909d`. The returned bytes had these Git blob
IDs, matching `git ls-tree` in the protected repository's local mirror:

| File | Ref | Git blob ID |
| --- | --- | --- |
| `docs/adr/0003-gating-runs-on-a-dedicated-gate-host.md` | `main` | `af77eccb9f4d28171df4308c3e44485da460529c` |
| `crates/jeryu-api/src/web/merge_queue.rs` | `60da213c7cd1eb8d1459e5b1ceda252616b5de9d` | `13fbf61683d4f1a261bd16191bda6eba5d2ba324` |

These are dated link and content checks; the ADR link follows `main`, while
the implementation link retains its immutable commit pin.

A released job is never scored, so a release reason must describe the ticket,
not the transport. A merge-queue or pull-request listing that fails transiently
-- HTTP 429, 408 or any 5xx, or no answer at all, such as a timeout -- is
therefore not a malformed ticket: the job is not released at all, so it lapses
with its lease and a later pass claims and audits the same valid ticket. Structural
refusals are unchanged and immediate: any other 4xx answer, an unreadable or
non-array page, exceeding the queue-list pagination bound, and every queue-content check
still release at once with the reasons above. Nothing is checked out on either
path.
