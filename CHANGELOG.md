# Changelog

This file is written when a release is cut: its notes are generated from the commits since the previous release. Do not add entries by hand; write a commit subject that says what changed.

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
- pr-redteam lands an exact-head approval through a separate scoped systemd unit
  while other reviews continue. Merge locks preserve the run lock and serialize
  with each PR's rereview. Poke keeps its restricted credential environment,
  retries failed starts and reports age from the completed review timestamp;
  installation stages the managed unit inactive and refuses active instances.
- Held-review Todoq filing defaults off, selects automation authors explicitly and caps
  new dispatch attempts per pass. Durable intent survives rereviews and uncertain CLI
  acknowledgement; unknown outcomes require owner reconciliation. Bounded findings are
  quoted data, workers must verify the original head, and old tasks receive stale notes.
  Automatic supersession closure and required-green-without-execution are removed;
  every PR head uses the real gate, including explicit re-gate requests.
- Failed or dequeued redteam merge-queue entries can be retried once per failed base, at most
  three acknowledged retries per reviewed head. Dry runs and transient failures do not consume
  retry state; accepted dispatch and bookkeeping share one receipt write. A bounded paged queue
  snapshot is read once per merge pass, with explicit state/base validation and diagnostics.
- pr-gate 1.10.0 adds protected-main health gates (`<repo>/main-health`), a release-guard
  setting and nightly template units. Activation is explicit and documented; main-health
  uses separate runner state/checkouts so its pass does not contend with a PR slot.
  Wake deduplication names the repository, PR and head in the current look; an earlier
  pushed SHA never suppresses a later PR opening. Current contribution, backoff and
  identity-before-checkout controls remain in place.
- Poke failures are separate heartbeat metadata and preserve the last real review;
  older heartbeat schemas receive the established fields. Failure notifiers retain
  their body environment variable with the screened, bounded body, and screening
  covers the full capture before truncation. Quoted pinned CLI paths install correctly.
- A PR gate starts on the pull request, not on the next timer slot. jeryu-deploy#267 (a two-line pin
  bump) was opened at 18:26:18 and its gate started 5m22s later, while the gate itself took 6m37s:
  the forge signals a push, not a pull request being opened, so the push for that branch was
  signalled before the pull request existed and nothing pointed a slot at it afterwards. The gate
  identity cannot read the pipeline event log (`GET /api/v1/events` is admin-only on the forge), so
  `pr-gate-wake.sh` now keeps reading the open-PR view alongside the signal, at most every
  `GATE_RUNNER_WAKE_HEADS_EVERY` seconds (default 10), skipping only the exact PR/head a signal
  names during that look. Each slot it starts is handed the head it was started for in `cache/wake-dispatch`, and the
  runner takes one line per tick and gates that head first of the pull-request heads its pass found,
  so a new head goes to whichever slot is idle instead of waiting behind a slot's own pass.
  Merge-queue entries still come first, the line decides nothing else, and a line nobody took or one
  older than `GATE_RUNNER_DISPATCH_TTL` (default 600s) is dropped unread -- the slot timers remain a
  sufficient fallback.
- Every gate records its queue wait, from the moment its head became gateable to the moment its gate
  started: `queue_wait: {ready_at, source, seconds}` on the attempt receipt, carried by the
  `gate.log` event as `detail.queue_wait` and named in its summary. The time is the forge's own when
  a wake-up carried one (`push`, `queue`, `regate`), else the pull request's own (`pr-opened`,
  `pr-updated`); clocks that disagree record an unknown wait with both times rather than a negative
  one. Gate latency is now measurable from the event log instead of inferred from two pages.
  pr-gate 1.6.0.
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
- A PR gate result is reusable on any gate host whose runner, tools, sources, settings and bound recipe
  environment agree. The input identity no longer names the host (`runner` is
  `pr-gate-runner`) or the paths a host installed things at; instead it binds every directory on the
  recipe's PATH (system directories by listing plus the installed package set, others by content),
  the OS, architecture and kernel, the whole toolchain bin directory and components, and Python
  distributions outside the package manager. The site configuration is bound as it is in effect
  (environment overrides included, first of repeated keys), minus host-local settings. The required
  status carries the inputs' digest (`; inputs <sha256>`). A runner with no receipt for those inputs
  adopts (success) or holds (failure) the forge's newest required status when this gate identity's
  runner (`creator.login`) posted it for exactly those inputs -- as a deferral: adopted heads are
  re-proved at idle or their next look, with a durable one-deferral marker. A newer
  agreeing success no longer supersedes a host's own verified receipt, and a success another host
  posted is not covered by `pending` while it is re-proved. Installing it re-gates every open head
  once, as any runner change does. Missing site files still bind effective settings; sandbox
  results bind implementation bytes and host custody; escaped tree names and one inputs field
  avoid ambiguous identity records. Cheap identities keep local compiler paths outside the portable
  input document and fall back to preparation for old receipts. Every sourced runner library,
  including backoff, is hashed and drained before replacement. Executable tree walks and read
  failures stop identity computation; directory-walk status is captured explicitly. System,
  component and Python enumeration errors likewise fail closed; absent Python roots stay an
  empty set. pr-gate 2.0.0.
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
