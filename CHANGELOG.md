# Changelog

## jeryu-ci-runner-v5.0.0-split.2
- Give the sandbox cgroup capability probe a unique leaf per probe and verify
  cgroup admission before job cgroups are created. Parallel probes in one
  process no longer remove each other's leaf, so the sandbox stops falling back
  to a cgroup it cannot join and failing job starts with EOPNOTSUPP (os error
  95) under systemd-managed sessions such as the PR gate runner slots.
- Replace `mem::zeroed` for `statfs` and `siginfo_t` with nix `fstatfs` and
  `waitid`, and confine the post-fork `_exit` to one module with real child
  exit-status assertions.
- Drop `http.postBuffer` and the Git protocol v0 pin from the hosted Cargo Git
  overlay: the hosted forge accepts gzip upload-pack bodies, and the tiny
  buffer is what aborts Git 2.43 under protocol v2. CI now fails if either
  setting reappears.

## Unreleased
- The PR gate decides reuse before it prepares anything. After refreshing the family's mirrors it
  derives the head's input identity without a checkout -- siblings from the mirrors' `refs/heads/main`,
  the gated head's own source row and recipe off the receipt that pins that exact commit, every tool,
  fixture and runner hash computed on the spot -- and leaves an unchanged head alone. In a 24h sample
  on the gate host two slots spent ~35 slot-hours re-preparing ~40 unchanged heads (~310 times each)
  only to find them identical, against ~8h of gating, with new heads queued behind that sweep. A
  sibling main that moved, a reinstalled governed tool or an upgraded runner is still a changed input,
  and anything the identity cannot be derived from counts as changed; only `reuse` and `hold` end a
  head this early, an explicit `--repo/--pr` and a re-gate the forge asked for never do, and the
  decision takes no claim of its own beyond the claim lock the head already holds. pr-gate 1.9.0.
- A merge-queue entry that arrives while a slot is deciding PR heads ends that slot's tick before its
  next head, so the next tick (within the timer's ~20s pause) gates the entry first. Entries were put
  first only when a tick started, and a tick can spend minutes walking heads that end in reuse: on
  2026-10-12 an entry waited 2m48s behind one such walk. Entries the tick already saw, admitted or
  refused, never end it, and neither does one another slot has claimed. pr-gate 1.8.0.
- `gate.log` events name the whole log and the slot that ran the gate. The tail is cut at a line
  boundary, so it no longer starts mid-token, and `detail.runner` carries `<host>/slot<N>` instead of
  leaving the runner readable only inside `summary`. Where a host's attempt logs are served,
  `PR_GATE_LOG_URL_TEMPLATE` (`{attempt}`, `{host}`, `{slot}`, `{repo}`, `{sha}`) becomes the event's
  `log_url`, so Activity's "Full log" link opens `build.log`; unset, no link is sent rather than one
  that 404s. pr-gate 1.6.0.
- The PR gate holds a contributed pull request until a maintainer allows it, and then runs it in a
  sandbox. A PR marked `PR_GATE_CONTRIBUTED_LABEL` (default `origin:contributed`, read from
  jeryu's own pull request row, as jeryu-deploy's importer marks it) executes nothing -- no recipe, no prefetch, no
  checkout -- until an `ok-to-test` from a login in `PR_GATE_OK_TO_TEST_MAINTAINERS` names its exact
  head (`GET /api/v1/gate-allowances?state=active`); a push moves the head and spends the allowance.
  An allowed head is gated through `PR_GATE_SANDBOX_COMMAND` with no forge token, no gate identity,
  no host home, no governed tools and no shared writable cache, and its result is published as the
  usual `<repo>/required` status, recorded as `sandboxed-contribution` in the status, the receipt and
  the input identity. A contribution that changes gate inputs (`PR_GATE_GATE_INPUT_PATHS`) is
  recorded in its receipt and named on its check run for extra review. Internal PRs are unchanged.
  pr-gate 1.5.0.
- A lane of the protected `jeryu-ci-runner/required` check passes only if it
  actually ran: `ops/ci/required-lane.sh` refuses a skipped, degraded, not-run,
  pending or tool-missing lane result and a run that collected zero tests. The
  workspace test suite asserts nextest reported tests, and the sandbox escape
  matrix can no longer be stood down. `ops/ci/tests/` holds the negative suite
  for each state and runs in `ops/ci/check.sh`. The jankurai pin drift block in
  `pr-ci.sh` is rendered by jeryu-tool and still skips when the renderer is
  absent; making it fail closed is a jeryu-tool template change.
- A gate starts on the push instead of on the next timer tick. `pr-gate-wake.sh` long-polls the
  forge's wake-up signal (jeryu-deploy: `GET /api/v1/gate-wanted?after=<seq>&wait=<secs>`, recorded
  when a push moves a branch, when the merge queue builds a queue commit and when a re-gate is
  asked for) and starts an idle slot per signal for a repository this host gates, so a head reaches
  a free slot in about as long as the push took rather than up to a tick later -- twice over for a
  pull request queued after its base moved. One signal buys one tick; a sequence that goes backwards
  is a restarted forge and resyncs without waking anything. A forge with no signal is read exactly
  as before, and the slot timers stay the fallback either way, so a missed signal costs only
  today's latency. `GATE_RUNNER_WAKE_WAIT` sets how long a look waits (default 30s), and
  `pr-gate-wake.timer` now looks 1s after the last one finished. No new credential: the signal is
  read with the gate identity, which sees only repositories it may read. pr-gate 1.4.0.
- The PR gate honours a re-gate asked for on the forge (jeryu-deploy: `POST
  /api/v1/repos/:id/pulls/:n/regate`, read as `GET /api/v1/gate-regate?state=pending`): a request
  naming an admitted head gates that head again although a terminal result exists for it, and is
  claimable at once even while a merge burst defers the automatic re-gates. The honoured
  `requested_at` is recorded in `regate/<owner>-<repo>-<sha>` when the attempt begins, so one
  request is one re-gate and asking again is a new one; `pr-gate-wake.sh` starts an idle slot for a
  fresh request. pr-gate 1.2.0.
- Fence scheduler transitions by the complete lease, runner epoch and current
  scheduler time. Expiration consumes retry attempts, cancellation is terminal,
  and an idempotent expiry sweep emits retry or failure receipts. Direct
  `LeaseBook::complete` and `fail` callers must now supply scheduler time.
- Split oversized sandbox launch, workcell, agent-driver, OAuth, registry, OCI,
  and fleet source into focused implementation and test modules without
  changing public Rust paths, serialized contracts, syscall ordering,
  fail-closed behavior, or test coverage; added truthful hosted-status and
  quick-start navigation to the repository entrypoint.
- Hardened runner-wire repository identity and time ordering for the hosted
  fleet: case-sensitive repository components are preserved, expired lease
  acknowledgements fail closed, and results cannot precede their finish time.
- v5.0.0 split baseline is present on the protected hosted forge; this runner
  wire tranche remains unmerged until its governed hosted checks and review land.
- Moved the workcell unit tests into their conventional Rust submodule without
  changing production code or test bodies; the combined real proof, security,
  and contract work raises the governed score from 83 to the fleet floor of 91.
- Bound the immutable Core dependency to an exact `git.neverhuman.org` transport
  policy and hosted preservation ref without changing Cargo source identity;
  added hostile pre-fetch transport tests, fixed-version networked security
  tooling, reviewed credential-helper custody, and a CycloneDX SBOM receipt.
- Updated the generated lock with the owning Cargo tool from `anyhow 1.0.102` to
  `1.0.103` to remediate `RUSTSEC-2026-0190` without moving any other package.
- Added a draft 2020-12 structural mirror for all 16 public runner-wire object
  types, with a Rust-bound hostile drift gate covering fields, enums,
  discriminators, collection bounds, and credential-field exclusion.
- Corrected the inherited stale v4 `VERSION` byte through the next immutable
  v5 split.1 identity and bound that exact identity into CI and SBOM metadata;
  the already-published split.0 tag remains untouched.
- Bound every CI-library Jankurai invocation to the physical pinned Cargo
  binary, including proof commands replayed through a login shell, with hostile
  custody, version, and PATH-shadowing regression coverage.
- Aligned proof verification with the pinned Jankurai schema's successful
  `pass` verdict while retaining fail-closed rejection of every reported issue.
- Compare protected-main and candidate scores under byte-identical policies and
  the same effective floor-91 override, preserving Jankurai's strict ratchet.
- Validate pinned copy-code and Rust witness artifacts against their emitted
  typed contracts, including zero hard copies and per-crate witness hashes.

## jeryu-ci-runner-v5.0.0-split.0 - 2026-06-11
- MAJOR: first standalone split-family release; the legacy monorepo
  is deprecated and its drift fully reconciled.

## jeryu-ci-runner-v4.0.0-split.0

- Initial split-family baseline for `jeryu-ci-runner`.
