# ADR 0003 addendum: forge-ticket audit admission

Status: Accepted (implementation; live host probe remains an owner step)
Date: 2026-10-21

This adds to jeryu-deploy's
[ADR 0003](https://git.neverhuman.org/jeryu/jeryu-deploy/blob/main/docs/adr/0003-gating-runs-on-a-dedicated-gate-host.md)
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
This response establishes field semantics; it is not a successful live audit.

The fixture builds independent PR heads before main advances and cherry-picks
them onto main and the previous queue replay, respectively. In addition to
checking the authenticated mapping, admission independently compares each
fetched queue tree with `git merge-tree --write-tree --merge-base=<fork>
<parent> <source>` before checkout. Conflicts, extra queue bytes, missing
source objects and ambiguous entries fail closed. A response that substitutes
the branch tip for a stacked replay parent cannot hide another contribution:
the expected tree excludes those undeclared changes and the comparison fails.
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
