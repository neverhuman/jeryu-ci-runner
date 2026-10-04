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
