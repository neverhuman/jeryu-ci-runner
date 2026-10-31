# Testing

Use the local CI entrypoints before pushing changes:

- `just fast`
- `just check`
- `just score`
- `just security`
- `just contract-drift`
- `just artifact-support`

`ops/ci/pr-ci.sh` is the canonical source gate for the protected hosted
`jeryu-ci-runner/required` context. `scripts/ci-local.sh` delegates to its narrow
host-reproducible lanes; `scripts/ci-doctor.sh` checks the required local tools.
The compatibility workflow must never be treated as a substitute for a genuine
hosted runner result.

`ops/ci/pr-ci.sh` ends with the proof evidence lane (`ops/ci/proof_evidence.sh`),
so the canonical gate as a whole is a network-, forge- and exact-head-bound
lane. It refuses a work-in-progress tree (the checkout must be clean, untracked
files included), an `origin` other than
`https://git.neverhuman.org/git/jeryu/jeryu-ci-runner.git`, and a head that
shares no history with protected `main`. The ratchet baseline is the current
protected `main` tip and the change set runs from the head's fork point, so a
head behind the tip is judged, not refused, and protected `main`'s own head (an
empty change set) skips the proof plan and still runs the audit, security,
migration and ratchet checks. Those checks compare the head's whole tree with
the tip's, so a stale head that scores below the tip, adds a cap or hard
finding, or raises migration liability fails them; the proof plan covers the
head's own change. It clones protected main from the
forge to audit the ratchet baseline. The lane writes
`target/jankurai/proof-evidence-summary.json`
(`jeryu.ci-runner.proof-evidence/v2`, contract in `proof_evidence_summary`,
`ops/ci/proof_guards.sh`); for an empty change set its proof digests, receipt
directory and proofmark count are null and `proof_verification` is
`not_applicable`. A shallow checkout
is deepened from the forge first. Run the narrower `just` lanes above on a tree
that is not yet a pushed, rebased head.

The baseline audit and migration analysis run on the unchanged protected-main
commit. The lane checks its HEAD, tracked files, untracked paths and policy
digest before and after auditing and after migration; the baseline report and
summary name that same commit. The only untracked or gitignored paths the baseline tree
may hold are the baseline audit's own report directory, `.jankurai/`; any other
untracked or ignored path refuses (the check lists ignored paths too, because
the auditor reads files whatever `.gitignore` says), because the audit and the migration analysis would read
it as bytes protected main carried. Before the policy digest pins that tree --
the pre-digest window -- the lane has already required the fresh clone to be the
exact base commit with no modified tracked file and no untracked or ignored path at all,
and between that check and the digest it only reads, so the bytes it hashes are
the bytes it compared.

Both audits receive the floor derived from protected main's policy.
Candidate policy bytes must match main unless their exact digest pair was
previously reviewed into main's `ops/ci/policy-transitions.txt`. A candidate
cannot authorize itself by editing that file. Beyond the digest pair a matched
pin re-checks exactly one field, the numeric `minimum_score`, and only that it
did not go down; `hard_findings_allowed`, `[scan] excluded_paths`,
`[dead_language] allow_terms` and the required auditor version are authorized by
the digests alone and rest on the review that landed the pin. An authorization
never rewrites the baseline, never moves the merge floor, and never overrides
the auditor's strict `policy_changed == false` ratchet.

The recorded 1.7.5 to 1.7.6 entry names the completed historical transition, and
both of its preimages are kept as immutable fixtures so the entry is checkable
rather than asserted: `ops/ci/tests/fixtures/audit-policy-1.7.5-preimage.toml`
(protected side) and `ops/ci/tests/fixtures/audit-policy-1.7.6-preimage.toml`
(candidate side). `ops/ci/tests/test-proof-guards.sh` hashes both against the
pinned pair, holds them to a difference of only the pinned auditor version,
accepts the pair through the guard and refuses the reverse pair. It does not
read the live `agent/audit-policy.toml`, so a reviewed change to the live policy
leaves this test meaningful; the pin authorizes no change to today's main.
Jankurai 1.7.6 rejects changed fingerprints, so a future migration also needs
reviewed auditor support for evaluating candidate code under main's policy; a
digest entry alone is insufficient.

The static `git commit` tripwire in `ops/ci/tests/test-proof-guards.sh` is a
line regex, not a shell parser. It catches `commit` as a bare word after
whitespace, `(`, `;`, `&` or `|`, at a line end, and across a `git \`
continuation. It does not see a quoted subcommand, a variable holding it, or an
alias; the runtime baseline guards are what cover those. Its scans of the lane
fail the test when grep cannot run, instead of reading that as a clean scan.

The security lane runs networked dependency checks by default through
`just security`. It preserves Cargo's immutable source identity while
`ops/ci/dependency-sources.sh` proves the active Git transport policy, hosted
tag/support-ref binding, Cargo Deny allowlist, and `git.neverhuman.org`
destination. Its evidence includes the exact lock hash and CycloneDX SBOM hash.
It hands the forge token only to a reviewed credential helper: the hosted gate
accepts exactly its own pinned helper, and an operator host running the gate by
hand opts in with `JERYU_CI_OPERATOR_HELPER=1` to also accept a reviewed
operator helper. The evidence records which one ran (`credential_helper_scope`).

The contract lane compares `schemas/jeryu.runner.v1.schema.json` directly with
the authoritative Rust wire sources and includes hostile drift cases. The
schema is a structural interoperability aid; runtime acceptance still requires
the Rust validator.

Agent-readable exception guidance:

- purpose: every typed error documents the caller-facing failure purpose
- reason: failures preserve enough context for local diagnosis
- common fixes: map repeated failures to a small set of operator repairs
- docs_url: point users to this file or a narrower runbook
- repair_hint: state the next command or config change to try

Cost and bounded-operation policy: budget, quota, spend cap, kill switch, and
stop condition evidence must be added before introducing paid or unbounded
network operations.
