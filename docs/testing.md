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
commit. The lane checks its HEAD, tracked files and policy digest before and
after auditing and after migration; the baseline report and summary name that
same commit. Both audits receive the floor derived from protected main's policy.
Candidate policy bytes must match main unless their exact digest pair was
previously reviewed into main's `ops/ci/policy-transitions.txt`. A candidate
cannot authorize itself by editing that file. The recorded 1.7.5 to 1.7.6 entry
names the completed historical transition; main already has its target bytes.
An authorization never rewrites the baseline or overrides the auditor's
`policy_changed == false` ratchet. Jankurai 1.7.6 rejects changed fingerprints,
so a future migration also needs reviewed auditor support for evaluating
candidate code under main's policy; a digest entry alone is insufficient.

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
