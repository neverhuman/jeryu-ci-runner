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
