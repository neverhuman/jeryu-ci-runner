# pr-gate

The PR gate runner: it gates open pull-request heads (and merge-queue commits) of the repositories it
is pointed at, on one gate host, and posts each repository's exact-head `<repo>/required` status.
Each gate builds a clean family tree from mirrors of every sibling's protected `main` plus the PR's
repository at exactly its head, runs that repository's own recipe (`just required`, else
`bash ops/ci/pr-ci.sh`), and publishes success or failure with the build log's SHA-256. Terminal
receipts and logs are kept for verified reuse and for publication recovery.

It never approves, merges, tags, pushes or waives anything, and it never proves a head its own
identity authored.

## Layout

| Path | What it is |
| --- | --- |
| `bin/pr-gate-runner.sh` | one tick of one slot: choose, claim, prepare, gate, publish |
| `bin/pr-gate-state.sh` | the durable attempt journal, input identity, publication and recovery |
| `bin/pr-gate-config.sh` | the site configuration reader every script uses |
| `bin/pr-gate-heartbeat.sh` | reports every slot to the forge's `/runners` page and finished attempts as events |
| `bin/pr-gate-wake.sh` | starts an idle slot as soon as a gated head appears, moves, or is asked for again -- on the forge's `gate-wanted` signal and from the open-PR view -- and hands it the head it started it for |
| `bin/pr-gate-install.sh` | keeps the installed copy equal to the source branch (drains slots first) |
| `bin/pr-gate-audit.sh` | claims the forge's queued jankurai audit jobs, scores each head with the governed jankurai in a throwaway clone, and submits the report (see [Scoring heads with jankurai](#scoring-heads-with-jankurai)) |
| `bin/pr-gate-advisory-refresh.sh`, `bin/pr-gate-grype-db-refresh.sh` | keep security databases fresh outside the gates |
| `systemd/` | the `--user` units and timers; `pr-gate-runner@N` is one slot |
| `tests/` | the offline regression suite (`tests/required.sh`) |
| `VERSION` | the component's own version |
| `pr-gate.env.example` | every site setting, with invented values |

On a gate host the scripts live in `~/gate-runner/bin`, the units in `~/.config/systemd/user`, and
the state under `~/gate-runner` (`installed-main.json`, `tools.json`, `attempts/`, `cache/`,
`regate/`, mirrors and trees). The units run `%h/gate-runner/bin/<script>`.

## Deciding reuse before a tree is prepared

Most of what a tick looks at is a head nobody has touched since it was gated. Finding that out used
to cost a full preparation -- a mirror checkout of every sibling, a reset, a clean, a tracked-file
stamp and a tree-wide fingerprint, about six seconds a head. In a 24h sample on the gate host
(2026-10-09/10) two slots spent some 35 slot-hours preparing about 40 unchanged heads, roughly 310
times each, against about 8 hours of actual gating, and a new head waited behind that sweep.

So after the mirrors are refreshed, and before anything is checked out, the runner derives the
head's input identity a second way (`gate_input_cheap`): the siblings straight out of those
mirrors' `refs/heads/main`, the gated head's own source row and recipe off the receipt that pins
that exact commit, and every tool, fixture and runner hash computed there and then. That is the
same document `gate_inputs` writes from a prepared tree, so the usual decision applies to it
unchanged, and an identical head is left alone without a tree.

Nothing is taken on trust. A commit determines its tree and its `Cargo.lock`, so a receipt whose
`sha` is this head is authority for that one row and for nothing else; the recipe and the toolchain
`rustup` resolves follow from that tree and from the `just` and `rustup` binaries, whose hashes are
recomputed, and the resolved compilers are re-hashed at the paths the receipt names. A sibling main
that moved, a governed tool that was reinstalled, a runner that was upgraded -- each is a changed
input here exactly as it is after a full preparation. Anything this cannot derive counts as changed
too, and the tree is prepared as before.

Only `reuse` and `hold` end a head this early: both run nothing and publish nothing, so neither
needs a tree. A retry of the head -- an explicit `--repo/--pr`, a re-gate the forge asked for -- is
precisely what must re-run a held failure, so it is never answered from the receipt and still
refreshes the head before it dispatches. The head is already inside its claim lock by then, so
deciding here takes no claim of its own and a slot that dies leaves nothing behind.

## Re-gating a head on request

A result is reused while its inputs are identical and a failure is held, so a head that failed on
something other than its own sources -- a dependency fetch that timed out, a host that lost its
compile cache -- needs somebody to ask for it again. The forge takes that ask (jeryu-deploy: `POST
/api/v1/repos/:id/pulls/:n/regate`) and the runner reads it each tick from
`GET /api/v1/gate-regate?state=pending`, as

    {"requests":[{"repo":"acme/widgets","number":7,"head_sha":"<40 hex>",
                  "requested_at":"2026-10-04T09:00:00Z","requested_by":"dana"}]}

A request for an admitted head it has not honoured makes the runner gate that head again although a
result exists for it, and lifts the coalescing deferral, so the head is claimable at once. What was
honoured is recorded in `regate/<owner>-<repo>-<sha>` when the attempt begins, which is what makes
one request one re-gate: the request is discharged by the attempt it started, not by its outcome,
and asking again records a newer `requested_at`. A request admits nothing the ordinary rules
refused -- this runner's own work, a closed pull request, a head that moved -- and `--repo/--pr`
reads no requests, being a retry already. A forge without the route (404) is silent; any other
answer is reported, because it would otherwise ignore every re-gate asked for without a word.

## Declaring sibling dependencies

By default, every canonical sibling main is an input to every gate in its family. A merge to an
unrelated sibling therefore invalidates existing results. After qualifying a repository's complete
gate with a smaller source closure, the operator can set `PR_GATE_DEPENDENCIES` in the site config:

```text
PR_GATE_DEPENDENCIES=acme/web=tool,core acme/tool=-
```

Keys are exact `owner/repo` names. Values list all same-owner sibling source dependencies, including
transitive ones, separated by commas; `-` means none. The gated repository is always included.
Unlisted repositories keep the default family or `GATE_RUNNER_FAMILY`. Paths, globs, duplicate keys,
duplicate dependencies and self references are refused. A declared sibling without canonical main
is an error, even though default family discovery tolerates scaffold-only siblings.

The runner fetches and prepares only the selected checkouts and moves old undeclared checkouts out
of the slot tree before running a recipe. Failure to remove one stops the gate. Both the declaration
and exact selected source identities are bound into the result. Changing a declared sibling still
re-gates; changing an unrelated sibling does not. Settle records live at `cache/mains/<owner>/<repo>`
so different closures cannot keep resetting each other's timer. Existing owner-wide records are
unused after upgrade. No site is enrolled by installing this code.

This controls sibling source inputs, not OS access: trusted recipes still have their normal host
permissions, and separately configured immutable evidence repositories remain available. Before
enrollment, audit recipes and helper scripts for sibling access and run the full required gate with
exactly the proposed checkouts. Add a dependency before introducing a new sibling read. A missing
optional read that a recipe silently skips needs an explicit assertion in that recipe; the runner
cannot infer dependencies from skipped code.

## Reusing ordinary compilation without retaining proof

`PR_GATE_BUILD_CACHE_REPOS` optionally selects full `owner/repo` names (or globs) for a separate,
physical, per-slot `target/build-cache` directory. Selected internal recipes receive
`JERYU_CI_BUILD_CACHE_DIR=target/build-cache`. The runner does **not** globally set `CARGO_TARGET_DIR`.
The recipe must explicitly use the directory only for ordinary compilation, for example:

```bash
CARGO_TARGET_DIR="${JERYU_CI_BUILD_CACHE_DIR:-target}" cargo check --locked --workspace
CARGO_TARGET_DIR="${JERYU_CI_BUILD_CACHE_DIR:-target}" cargo nextest run --locked --workspace
CARGO_TARGET_DIR=target/coverage-build cargo llvm-cov --json --output-path target/coverage.json
```

Everything else under `target/`, including coverage builds, profiles, reports and proof receipts,
starts fresh. Never put instrumentation or gate evidence inside `build-cache`. This contract needs
a complete recipe audit and cold/warm qualification before enrollment; the runner cannot classify
arbitrary files a recipe writes. Installing the feature enables no repository automatically.

Only a completed successful gate authorizes reuse. Tool, runner, configuration, recipe, lock or
sibling-source identity changes discard it; an ordinary change to the gated repository's source
can reuse it. Cargo still checks source freshness, and the runner stamps tracked files on checkout.
An interrupted, failed or input-changing attempt leaves no authorization for its cache. Contributions
get a clean target and no cache variable, and revoke any prior authorization for that slot/repository.
Opting out restores fully clean targets. Symlinked cache directories and overlap with
`GATE_RUNNER_SHARED_TARGETS` are refused. No cross-slot cache or extra repository lock is introduced.

## Starting a gate when the head appears

A slot looks for work when its own timer fires, so a head that appeared just after a tick waited for
the next one, and behind every gate running in between. `pr-gate-wake.sh` runs from its own timer and
starts an idle slot the moment it learns a head can be gated, from two sources:

- the forge's wake-up signal, `GET /api/v1/gate-wanted?after=<seq>&wait=<secs>` (jeryu-deploy),
  recorded when a push moves a branch, when the merge queue builds a queue commit and when a re-gate
  is asked for. One long-polled request per look, no per-repository reads;
- the open-PR list of every gated repository, the building merge-queue entries and the pending
  re-gate requests, waking on a line that view gained. This is the only source against a forge
  without the signal. Alongside the signal it still runs, at most every
  `GATE_RUNNER_WAKE_HEADS_EVERY` seconds (default 10), because the signal cannot cover a pull request
  **opened** on a branch that was already pushed: the push was signalled before the pull request
  existed, so nothing pointed a slot at it and it waited for a timer. Only an exact PR/head named
  by a signal in the same look is skipped by the view; a pushed SHA alone cannot suppress an opening.

Before starting any slot, the waker saves every new head hint as one line of
`~/gate-runner/cache/wake-dispatch` (`<owner/repo> <number|-> <sha|-> <source> <when|->`). The runner
takes one line per tick and gates that head first of the pull-request heads its own pass found --
merge-queue entries still come first, each being one gate from landing -- and dates the queue wait
from `<when>`. The line decides nothing else: the tick still lists, chooses, claims and gates heads
by the ordinary rules, which is what keeps the slot timers a sufficient fallback. Hints survive busy
slots and failed service starts for the next scheduled tick (normally 20–25 seconds after a slot
finishes). Saving hints happens before acknowledging the signal or updating the observed PR view;
a failed write leaves that view available to retry. The file keeps at most the newest 64 hints.
Dated hints older than `GATE_RUNNER_DISPATCH_TTL` seconds (default 600) are dropped when read.
This is bounded priority, not a durable work queue: current forge state remains authoritative.

## How long a head waited

Every gate records its queue wait on the attempt as
`queue_wait: {ready_at, source, seconds}` -- from the moment the head became gateable to the moment
its own gate started -- and the `gate.log` event carries it as `detail.queue_wait`, so gate latency
is a number a reader can measure instead of two timestamps on two pages. `ready_at` is the forge's
own time when a wake-up line carried one (`source`: `push`, `queue`, `regate`), otherwise the pull
request's own (`pr-opened`, `pr-updated`): an unrelated change to a pull request can only make a
measured wait shorter, never invent one. Clocks that disagree record `seconds: null` and keep both
times rather than a negative wait.

## Main health

`pr-gate-runner.sh --main-health` gates each protected repository's current `main` with the same
recipe and governed tools as pull-request gates, then posts `<repo>/main-health` on that main
commit. That context is deliberately distinct from `<repo>/required`, so it cannot satisfy branch
protection for a pull request. A scheduled pass skips a repository whose main SHA already has this
runner's latest green main-health status; `--main-health --repo owner/name` runs that repository on
demand. If `GATE_RUNNER_RELEASE_GUARD_FILE` names an existing file, main-health exits quietly so it
does not compete with a release.

`pr-gate-wake.sh` also starts one main-health slot as soon as the forge's signal reports a push to a
default branch, so main is gated when it moves instead of at the next timer tick. It says only WHEN:
the pass gates whatever main is by then (newest head wins) under the same slot lock, which keeps it
to one gate per repository, and a slot that is mid-pass is left to finish. A push that found every
slot busy is kept in `cache/wake-main-pending` and woken on a later look, because the fallback behind
main-health is its own far-apart timer. A red main SHA is gated again on the next pass (only a green
one is skipped), which is what tells a flake -- the same commit failing and then passing -- from a
defect that stays red; jeryu folds both out of the `main.status` events the heartbeat posts
(jeryu-deploy: `GET /api/v1/main-health`), and a failed attempt's event names the failing tests the
recipe output reported.

The installer stages the template units but does not activate their instances.
To schedule the nightly pass, the service owner creates
`~/gate-runner-main-health/pr-gate.env` with the required site settings and
independent checkout, mirror and target paths under `~/gate-runner-main-health`.
It may refer to the existing governed binaries and credential file. The main-health
unit uses this separate home, so its slot lock and checkouts do not collide with PR gates.
After configuring it, enable `pr-gate-main-health@0.timer` with
`systemctl --user enable --now pr-gate-main-health@0.timer`.
Installing this source does not run that activation or a live deploy.

## A head that changes its own gate

The gate runs the recipe **at the head under test**, so a diff that rewrites that recipe rewrites the
check which then passes it. Each gate therefore diffs the head against the repository's protected
`main` (`mirror/main` in the tree) for the paths that define the gate -- `Justfile` anywhere,
`ops/ci/**`, `ops/jankurai/**`, any `*jankurai*` file and `policies/**`, excluding `docs/**` -- and
records them on the attempt as `gate_definition_paths`.

When the list is not empty the check run `pr-gate-runner` says so: `output.summary` ends with
`changes its own gate` and `output.text` names the paths and what to do. The required status is
untouched -- it is the gate, and its description must stay the gate's own verdict -- and the
conclusion is unchanged: this is a flag for a person, not a veto. Running the recipe from protected
`main` instead is deliberately **not** done (owner decision, 2026-10-02).

jeryu's attention inbox raises the matching item from the same path set, so such a pull request also
appears on `/needs-you` (jeryu-deploy: `pr_changes_own_gate`).

## Contributed pull requests

The GitHub repositories are read-only mirrors; an outside contribution is imported to the forge as a
PR the importer marks with `PR_GATE_CONTRIBUTED_LABEL` (default `origin:contributed`, read from
jeryu's own pull request row -- `GET /api/v1/repos/:id/pulls` and `.../pulls/:n` -- where
jeryu-deploy labels every row `origin:internal` or `origin:contributed`; the GitHub-compatible v3
read carries no labels). A row with no marking at all is internal, so a forge older than the marking
gates as before. Such a head carries
code nobody of the family wrote, so the runner executes **nothing** of it -- no recipe, no
locked-crate prefetch, no cache daemon, and it is not even checked out -- until a maintainer has
allowed exactly that head. An internal PR is unaffected and keeps the path above.

The allowance is the `PR_GATE_OK_TO_TEST_LABEL` (default `ok-to-test`) a maintainer applies on the
forge, which the runner reads each tick from `GET /api/v1/gate-allowances?state=active` as

    {"allowances":[{"repo":"acme/widgets","number":7,"head_sha":"<40 hex>","label":"ok-to-test",
                    "allowed_by":"dana","allowed_at":"2026-10-06T09:00:00Z"}]}

at most one per PR. The runner decides for itself, and fails closed: the allowance must name the
PR's *current* head, carry the configured label, and come from a login in
`PR_GATE_OK_TO_TEST_MAINTAINERS`. So a push moves the head, the allowance no longer names it, and
the new head waits for a new one -- an ok-to-test is spent by the push that follows it. A forge
without the route, one this identity cannot read it from, or an unconfigured maintainer list allows
nothing; each is reported as the reason that head is not running, and no status is posted (the PR is
waiting for a maintainer, not failing). jeryu-deploy does not serve this route yet, so on a jeryu
forge today every contribution waits here: that is the fail-closed answer, not a fault.

An allowed head is gated in `PR_GATE_SANDBOX_COMMAND`, the site's ephemeral, network-restricted VM
or container, called as

    <command> <tree-root> <repo> <recipe...>

which mounts the tree root at that same path in the guest, enters `<repo>` and runs the repository's
own recipe. What the runner guarantees on this side is that the execution has nothing of the gate
host: `env -i` with no forge token and no path to one, no `GATE_RUNNER_IDENTITY`, no `HOME` or `USER`
of the gate user, `PATH` is `PR_GATE_SANDBOX_PATH` and not the governed tools, no compile cache
(`sccache` and `GATE_RUNNER_SHARED_TARGETS` are off, so it builds in its own tree), no prefetch into
the shared Cargo registry, no runtime-tools or native-vendor link out of the gate home, and no mount
namespace of ours. With no sandbox configured, an allowed contribution still runs nothing. The result
is published as the usual exact-head `<repo>/required` status, and `sandboxed-contribution` is in its
description, its receipt and its input identity -- so a sandboxed result is never reused as a
host-run one, or the other way round.

A contribution that changes what the gate itself evaluates with (`PR_GATE_GATE_INPUT_PATHS`:
`ops/ci/`, `ops/ci-kit/`, `ops/pr-gate/`, `.jeryu/ci.toml`, `Justfile`, workflow directories) is
compared against the merge base with protected `main`; the paths it changes are recorded in its
receipt as `gate_input_paths` and its check run's summary says `gate inputs changed: extra review
required` (beside the self-gate annotation above, never on the required status). That never changes
whether the gate runs -- it is a green gate that still needs a human to read the change.

## Scoring heads with jankurai

The forge keeps one jankurai audit job per pushed head of `main` and of every open pull request
(branch, head, base, `diff` or `full`) and completes `jankurai/proof` only from a report that comes
back through its authenticated ingest and matches the job. `pr-gate-audit.sh`, from
`pr-gate-audit.timer` (30 s after the previous pass), is that producer:

1. claim at most `PR_GATE_AUDIT_MAX` (default 1) jobs as `<short host>/jankurai-audit`
   (`POST /api/v1/jankurai-audits/claim`), unless the shared back-off says wait;
2. admit only the repositories this host serves (`GATE_RUNNER_REPOS`, else every repository of
   `GATE_RUNNER_OWNERS`, as the slots and the wake timer choose them), and in them only reviewed code: a
   job for `main` whose head the clone's own `main` reaches (the ticket's word is not enough), or the
   head of an open pull request the forge marks `origin:internal` (`PR_GATE_INTERNAL_LABEL`; every page
   of open pull requests is read, and a label may sit on the row or under its summary). A contribution (`origin:contributed`), a head no open
   pull request holds, or a forge that cannot answer is left alone -- like the slots, this host checks
   out nothing of a contribution. A job left alone is not refused on the forge (there is no route for
   that); its claim lapses with its lease;
3. clone the head under the gate home (`audit-work/`, swept at the start of each pass) with the gate's own credential (through a git credential
   helper that reads the token file; it is in no argv, environment or clone config);
4. make the tree safe to audit and give it trusted metadata. Everything the auditor reads besides the
   code -- `agent/` (policy, generated zones, boundaries, test and owner maps) and `.jeryu/` (the CI
   declaration) -- comes only from a commit `main` reaches, so a head can neither lower its floor nor
   mark its own files generated or excluded: the job's base when `main` reaches it, the head itself when
   the job is `main`'s (admission proved it is on `main`), else `main`'s current tip (a pull request
   stacked on an unreviewed branch is scored by `main`'s metadata, never that branch's). With no `main`
   at all the metadata is removed and the default policy is used (the forge's floor of 85, the verified
   auditor's version, no exclusions). Every symlink that resolves outside the clone is removed and the paths the
   auditor writes to (`.jankurai`, `target`) become real directories. Every tracked path this changes is
   then marked assume-unchanged, because `diff-audit` scores the worktree against the base: the score
   must reflect only what the head committed, never the hardening;
5. run the host's governed jankurai there with the family's own invocations: a `diff` job exactly as
   `ops/ci/jankurai-gate.sh` renders the host's (`diff-audit --base-ref <base> --advisory-only`, plus
   `--skip-proof` without an owner map), a `full` job (a head with no commit base) as `ops/ci/score.sh`
   audits a tree (`audit --full --mode advisory --policy`); niced, idle I/O, and time-boxed by
   `PR_GATE_AUDIT_TIMEOUT` (default 900 s). A head that a branch no longer points at is fetched through
   `refs/pull/*`. Every git command of the pass -- the checkout above all -- and the auditor itself run
   with no LFS smudge, no prompt and no global or system git configuration; the auditor's output reaches the journal only as a
   bounded, printable tail;
6. submit the report from a file (`POST /api/v1/repos/<owner>%2F<repo>/jankurai-scores`), naming the
   auditor's version, sha256 and installation receipt -- the forge refuses any other auditor. The report
   carries `jeryu_audit_policy` (`source` -- the base commit or `default` -- and the policy's sha256),
   so a reader comparing it with a local run of the head's own policy can see why they differ.

Each job runs in its own subshell: whatever a head does to its own audit, the job is reported
`failed` and the pass goes on to the next one.

The report submitted is always the one this script produced. A recipe that audits its own head (most
`required` recipes enforce a score floor) writes a report too, but that file is written by the code
under test, so it is never what the forge is told the governed auditor found.

The auditor is the one the host's installer keeps current and verifies: `bin/pr-gate-ensure-jankurai.sh`
is the repository's generated verifier (`ops/ci/ensure-jankurai.sh`, a fixed path, installed beside the
scripts by `pr-gate-install.sh`). It is sourced with the switches that would widen what it accepts
(a test receipt, a caller-named receipt or authority, a release broker) unset. It checks the binary, its
installation receipt and the host's authority stamp, and a host whose auditor does not verify audits
nothing (each pass says why, claims nothing and beats `/runners` with the reason as its `last`; the
unit does not fail every 30 s). The token's curl config is a 0600 file in the gate's `cache/`, never
beside a clone. When the tool pin
moves, the host's tool installer replaces the binary and receipt, and the next pass audits with the new
version. The verifier is code sourced next to the credential that changes without draining or
re-gating: it comes only from `ops/ci/ensure-jankurai.sh` on the protected source branch (itself a gate
input path), is rendered there by the tool pin's owner, and is not digest-pinned here because a pin
move must reach it without a pr-gate release.

Each pass beats `/runners` as `<short host>/jankurai-audit` (label `jankurai-audit`): `current` while
an audit runs (kept alive every `PR_GATE_AUDIT_BEAT_EVERY`, default 60 s) and `last` when it ends --
`scored`, `tool-failed` (the auditor wrote no usable report; it is still submitted, with its exit),
`refused` (the forge refused the submission, e.g. a 409 for a job already taken, or a 422 for an
auditor it does not accept) or `failed` (the head could not be fetched). A refusal never fails the pass.

It runs wherever `pr-gate-audit.timer` is installed; mask the timer to keep a host from auditing. A
pass refuses a `PR_GATE_AUDIT_MAX` x (`PR_GATE_AUDIT_TIMEOUT` + 300 s) that would not finish inside the
unit's 10 h `TimeoutStartSec`, and audits at most `PR_GATE_AUDIT_MAX` jobs whatever the forge hands out. The
gate identity must be allowed to submit scores on the forge (an administrator, or listed among its
jankurai scorers) and must not author the pull requests it scores. Set the tuning keys
(`PR_GATE_AUDIT_*` including `PR_GATE_AUDIT_TOOLS`, `PR_GATE_INTERNAL_LABEL`) on the unit with a drop-in `Environment=` line, not in `pr-gate.env`: every
`PR_GATE_*` key in the site file is bound into each gate's inputs unless it is host-local, so a key
added there would re-gate every open head. A forge without the audit routes answers 404/405 and the
pass ends quietly. The script never takes a gate lock, posts a commit status or touches a gate tree,
and it is not a gate input: installing a new version of it re-gates nothing.

### Bound jobs: the forge assigns the auditor (ADR 0011, as superseded by ADR 0012)

When the forge's `/api/v1/capabilities` reports `jankurai_audit_jobs.binding >= 1`, the pass switches to
the bound contract; an older forge keeps everything above unchanged.

- **Staged auditors.** The host's tool installer stages every approved auditor side by side, keyed by
  its binary digest: `<tools>/jankurai/<binary sha256>/bin/jankurai` and `.../receipt.json`
  (`PR_GATE_AUDIT_TOOLS`, a host path set on the unit; default `~/.jeryu/tools`). Each one is checked on
  its own installation receipt -- binary digest, `jankurai --version`, `test_mode` false, signature
  verified, governed -- and the verified digests are what the claim offers
  (`capabilities: {jankurai: [...], sandbox: false}`) and what the heartbeat's `tools` lists. No
  release-specific verifier is involved, so an auditor release reaches this host without a pr-gate or
  consumer change.
- **Each job names its auditor** (`auditor`: manifest revision and digest, version, target, binary and
  signer digests), its `metadata_commit` and `policy_sha256`, its `origin` and its `purpose` (`proof` or
  `qualification`). Before anything is checked out, the assigned auditor must be staged here and match
  that identity on its receipt; it is checked again right before it runs. The receipt's install-time
  manifest is not compared: one binary stays approved across manifest revisions.
- **Metadata and policy come from the job.** `agent/` and `.jeryu/` are taken from `metadata_commit`,
  which main must reach, and its policy (or the fixed default, whose bytes name no auditor version) must
  hash to `policy_sha256`.
- **A job this host will not run is handed back at once**
  (`POST /api/v1/jankurai-audits/:job_id/release {reason}`) with one of `not-served-by-this-host`,
  `contributed`, `not-on-main`, `malformed-ticket`, `policy-mismatch`, `staged-digest-missing`,
  `verifier-mismatch` or `tool-gone` (the auditor vanished or changed after the claim), and reported
  `released`. It is never scored.
- **The submission echoes the binding** (`job_id`, `auditor`, `metadata_commit`, `policy_sha256`, head,
  base, `receipt_sha256`); the forge refuses any difference, and the pass reports
  `rejected-publication` with the forge's reason. A qualification job's report is recorded as
  qualification evidence (202, `recorded_as: qualification`) and reported `qualified`.
- **States.** While an audit runs, `current.state` is `running`, then `publishing`; a forge that does
  not know the field gets the beat without it.

## Site configuration

Nothing in this directory names a site. Everything that does -- the forge URL, the credential file,
the gate identity, the owners and where their checkouts live, repositories with an unusual required
context or special build needs, where the installer fetches from -- is read at run time from

    ${PR_GATE_CONFIG:-~/.config/jeryu/pr-gate.env}

as `KEY=VALUE` lines. The file is data: it is never `source`d, only `PR_GATE_*`, `GATE_RUNNER_*`,
`GATE_INSTALL_*` and `JERYU_*` keys are taken, and a value already set in the environment wins, so a
unit's `Environment=` line or a per-slot drop-in still overrides it. A required setting that is
missing stops the script with `<KEY> is not configured`. `pr-gate.env.example` lists every key.

The runner hashes the site configuration into each gate's input identity, as it does its own code:
changing a setting that can change a verdict re-gates open heads once, exactly like installing a new
runner. What is hashed is the configuration in effect -- a value set in the environment (a unit's
`Environment=` line, a per-slot drop-in) wins over the file, and of repeated keys the first wins, as
the loader decides. Settings that only say where this host keeps things, which credential it reads,
which repositories it gates or when it wakes (`GATE_HOST_LOCAL_SETTINGS` in `bin/pr-gate-state.sh`)
are left out, and so are comments and order; every other key is bound, including ones added later.
The ok-to-test and contributed-label settings are bound: they decide whether outside code may run.
Missing or unreadable files still bind every effective environment setting and an explicit absent-file
sentinel. Such a runner never silently drops configuration from its identity.

## Results across hosts

An operator-run result names its inputs independently of the host that computed them. The input identity names the runner
(`runner: "pr-gate-runner"`), never the host, and binds what the recipe can execute by content and
name, never by the path a host installed it at:

- the named tools, governed tools, runtime fixtures, vendor tree and every sourced runner/config/state/backoff script;
- every directory on the recipe's `PATH` (`RECIPE_PATH`, the only PATH a recipe and its prefetch get):
  a system directory (under `/usr`, not `/usr/local`; `/bin`, `/sbin`) by its listing plus the
  installed package set, which also covers `/usr/lib`; any other directory (`~/.local/bin`,
  `~/.cargo/bin`, `/usr/local/bin`, ...) by the content of every file in it;
- the OS release, architecture and kernel release, the active Rust toolchain's whole bin directory
  and installed components, and Python distributions installed outside the package manager.

A host whose package set cannot be read binds a value unique to itself and so never shares a
result. System directories use package versions plus names, sizes and link targets; this assumes
operator-managed package files and does not detect same-size local tampering. Other bound trees use
content hashes and escaped relative names. Unreadable executable inputs fail closed; they never
share a constant portable identity. This operator-unsealed identity is not a sealed worker.
Sandboxed contributions additionally bind the sandbox executable, OS/kernel and machine identity:
results remain host-specific until an independently bound guest-image contract exists.

A changed package, executable or Python distribution during a recipe invalidates that attempt as
`inputs_changed`, even when the recipe exits zero. Keep operator installations outside gate windows;
freezing mutable tools would permit publishing a result for bytes that changed during execution.

The required status carries the identity's digest (`; inputs <sha256>`, the SHA-256 of the compact,
key-sorted inputs JSON; `gate_inputs_digest`). Who posted a status is the forge's `creator.login` on
the combined status, never its description. A runner decides from its own receipt first; a newer
success this gate identity posted for exactly the same inputs confirms that receipt rather than
superseding it, so hosts do not bounce a head between them. When it has no receipt for these inputs
-- another host gated the head, or the host is new -- it reads the forge's newest required status: if
this gate identity posted it (`creator.login == GATE_RUNNER_IDENTITY`) from a pr-gate runner and it
names exactly these inputs, a success is adopted and a failure held. A retry (`--repo/--pr`, a re-gate
request) always runs.

Adoption is allowed once per head/input identity. A durable `forge-deferred.json` marker records
that deferral before skipping the head, including across process restarts. On its next look, that head
runs even if the tick is busy; an idle tick can re-prove it immediately with forge reuse off
(`idle: re-proving ...`). Capacity and queue priority still determine when a head is visited. A forge
status never substitutes for a verified local receipt indefinitely. A runner also leaves a success another host's runner
posted in place instead of posting `pending` over it while it re-proves. A forge that shortened the
description would drop the digest; the runner reports that, and other hosts then simply re-gate.
Parsing requires exactly one inputs field. Cross-host adoption requires the authenticated exact
creator login. Keep-green retains the old own-host marker fallback for account renames; that fallback
suppresses pending only and never authenticates adoption.

Claims are still local, so two hosts must not gate the same owners at once; failover is moving an
owner from one host's `GATE_RUNNER_OWNERS` to the other's.

## Version

Version 3.0.0 moves the mains settle records from owner-wide files to per-repository paths as
described above. Existing attempt journals and status/receipt formats are unchanged. Upgrade in a
single drained install after the 2.1.1 audit fix; the installer handles the usual input invalidation.
Dependency and build-cache enrollment remain separate operator configuration changes.

`VERSION` is the gate component's semantic version, independent of this repository's release tags:

- **patch** (1.0.x) for fixes that change no behaviour a host or forge relies on;
- **minor** (1.x.0) for new behaviour or new optional settings;
- **major** (x.0.0) for contract changes: a required setting added or renamed, the installed layout,
  unit names or state files changed, the heartbeat/status/receipt shape changed. An optional field
  added to a receipt or an event is minor: every reader of the older shape still reads the newer one.

Bump it in the same change as the code. The installer records `pr-gate <VERSION>` read from this file
at the installed commit, and each heartbeat reports the installed code as
`code: {repo, commit, version, installedAt}`, where `repo` is `PR_GATE_CODE_REPO` (no code is
reported without it), `commit` the installed commit, and `version` e.g. `pr-gate 1.0.0`.

## Installation and updates

`pr-gate-install.sh` runs from `pr-gate-install.timer` every 10 minutes. It fetches
`PR_GATE_SOURCE_BRANCH` (default `main`) of `PR_GATE_SOURCE_URL` into its own bare mirror
(`~/gate-runner/source/pr-gate.git`), and compares `PR_GATE_SOURCE_SUBDIR` (default `ops/pr-gate`)
`bin/pr-gate-*.sh` and `systemd/pr-gate-*.{service,timer}` there, and the repository's governed-jankurai
verifier (`ops/ci/ensure-jankurai.sh`, installed as `bin/pr-gate-ensure-jankurai.sh`), with the
installed copies. The verifier is not a gate input and drains nothing, but `pr-gate-audit.sh` sources
it next to the credential, so it comes from that one path of the protected source branch only. A change to
the runner, its state library or its config library drains every slot first (stops the slot timers
and waits for running gates, at most 45 minutes, else installs nothing and retries). Each changed file
is installed atomically with its predecessor kept as `<file>.<old>-pre-<new>.bak`; a unit change
reloads systemd and enables the managed singleton timers. The installed commit is recorded in
`installed-main.json` (`{commit, previous, installed_at, files, version}`, or `{commit, verified_at,
version}` when nothing differed), and every run records what the gates evaluate with in `tools.json`.

First installation on a new host: put the site file in place, copy `bin/*.sh` to `~/gate-runner/bin`
and `systemd/*` to `~/.config/systemd/user`, `systemctl --user daemon-reload`, then enable
`pr-gate-install.timer` (it enables the other singleton timers) and the slot timers
`pr-gate-runner@0.timer` .. `pr-gate-runner@N.timer`.

## Compatibility: a runner newer than its forge must degrade, not flood

The runner is installed from its own branch and the forge is deployed separately, so a runner can run
against a forge that lacks a route or field it knows (pr-gate 1.4.0 met a forge with no
`gate-wanted`, and gating stopped for the whole host). Every new dependency on the forge needs a
degraded mode that costs the forge no more than the slot timers do:

- **wake**: `pr-gate-wake.sh` does nothing unless the forge serves `GET /api/v1/gate-wanted`. A 404 is
  cached for `GATE_RUNNER_WAKE_PROBE_TTL` seconds (default 600) and any other failed look pauses the
  signal for a minute; the slot timers carry the work. With a working signal the open-PR view is
  also read every `GATE_RUNNER_WAKE_HEADS_EVERY` seconds. Without the signal, reading gated heads is an operator opt-in
  (`GATE_RUNNER_WAKE_POLL_HEADS=1`) and then at most every `GATE_RUNNER_WAKE_POLL_INTERVAL` seconds
  (default 30).
- **429**: a 429 on any read starts one shared back-off (`cache/forge-backoff`, `pr-gate-backoff.sh`):
  `Retry-After` is honoured, otherwise 30s doubling per consecutive 429 up to 15 minutes
  (`GATE_RUNNER_BACKOFF_BASE`, `GATE_RUNNER_BACKOFF_CAP`). Until it passes, no slot, wake or head read
  sends a request; the first non-429 answer clears it. Status writes still go out.
- **heartbeat**: a 422 drops `tools`, then `code`, then falls back to the oldest contract
  (`gate_heartbeat_minimal`), so `/runners` stays alive. The heartbeat timer remembers the level that
  worked for 30 minutes (`cache/heartbeat-level`).
- **installer**: `pr-gate-wake.timer` is enabled only when the forge answers `gate-wanted` with 200
  (it is considered again on the next unit change, or enable it by hand), and a unit the operator
  masked (a `/dev/null` link in the unit directory, or masked in the user manager) is neither
  overwritten nor enabled.

## Qualification

`bash tests/required.sh` runs the whole suite offline: the config reader, the attempt journal and
publication recovery, the complete runner against a fixture forge and real Git (including re-gate
requests), contributed heads (no ok-to-test, a stale or outside one, the sandbox's own environment), the
mount-namespace selection, lock inheritance, heartbeat and event projection, waking,
retention, the locked-crate prefetch's source allowlist, the installer and the database refreshers.
Every fixture uses invented names (`acme`, `gate-a`, `example.test`); none reads the host's own site
file. The repository's `ops/ci/pr-ci.sh` runs it.

The complete-runner protocol suite uses a private child home and small fixture Rust tools: its
recipe never compiles Rust. This avoids hashing the developer's unrelated user tools and full
compiler installation on every synthetic dispatch. The runner still computes real content
fingerprints, and compiler/user-tool byte changes must invalidate reuse even when their version
strings stay the same. The state suite separately exercises the host enumeration and refusal
paths with the installed toolchain. No production fingerprint cache or validation is bypassed.

The required gate discovers both the PR-gate and review-controller families with
checked `required.sh --list` calls before dispatching any suite. A failed, empty,
invalid or repeated list fails the gate. The shared pool uses
`JERYU_CI_SUITE_JOBS` (default 2, range 1–4), separately from Cargo's worker count.
Each suite is named when it starts, then its combined output is printed together
when it finishes. The pool requires Bash 5.1 or newer.

Executable input trees must be readable by the gate identity. `cannot bind executable input` or
`cannot walk input tree` stops identity computation and names the affected tree/file. Operators
restore tool-tree readability or relocate execute-only tools before retrying; the runner never
adopts an identity assembled from unreadable executable contents. Directory enumeration captures
and checks the find/sort pipeline status explicitly rather than depending on process-substitution
PID behavior.

Forge-status adoption leaves an authenticated gate-account status in place for one visit. A forged
status from that account can therefore survive that visit until local re-proof; operator-unsealed
recipes already run as that account and can read its credential. This is an accepted operator-host
assumption, not a sealed execution claim. Contributed sandbox recipes receive no credential helper.

System-directory listings, installed toolchain components and Python distribution enumeration also
fail identity computation on command errors. Missing Python installation directories represent an
empty distribution set; unreadable existing directories and failed rustup/find commands do not.

## What the gate is checking, and how long each step takes

While a gate runs, the runner reads the step lines its recipe prints (`[pr-ci] <step>`,
`[ci] required|fast lane: <step>`, `==> <step>`, and npm/pnpm's `> <pkg>@<version> <script>` run
banner, as `npm <script>`) from the attempt's `build.log`, and records when each first appeared in
`steps.tsv` (`epoch<TAB>step`, beside the log; `steps.end` holds the end). Only complete lines count,
and tabs and control characters become spaces. It posts the list as the `pr-gate-runner` check run's
summary when a step starts, at most once every 15 s and at least every two minutes:

    ✓ jankurai pin drift check · 4s
    ▸ cargo clippy · 1m12s so far
    ○ cargo test · usually 3m05s

**Step names are not log text.** The recipe is the head's own and runs as the gate user, so it could
print a credential as a step. A step is published by name only when that text occurs literally in the
repository's gate sources on protected `main` -- Justfiles, `ops/`, `scripts/`, Makefiles and
`package.json` files, read from the mirror at gate time into the attempt's `step-sources` -- is in a
short charset, and is cut to 80 characters. Any other step is published as `step N`. At most 60 steps
are listed (the latest, with a count of the earlier ones). The real text stays in `steps.tsv` on the
runner, as the log does (the same rule as the failure cause: nothing free-form from the log is
published).

`○` steps and their "usually" come from the repository's last green attempt that recorded its end
(`$HOME_DIR/cache/steps-<owner>__<repo>.tsv`). The finished check run lists every step with its time
(`✗` and the cause on the step that failed). For a pull-request head, the required status and the
check run link to that PR's checks page, built from the `html_url` the forge returns for exactly that
PR when it is admitted (`<html_url>/checks`); a merge-queue commit and main-health link nothing. A
forge that refuses the link (422) gets the same status or check run without it, so the link never
fails a gate. Live posts are skipped while the shared forge back-off is running and never clear it.
Times are first-seen, polled every 2 s.

`bin/pr-gate-steps-report.sh [--all] [--days N] [OWNER/REPO...]` ranks each repository's steps by
median time over its green attempts (all with `--all`), with p90, max, share of the total and run
count: the numbers for deciding whether a long, low-value step should leave the required gate. It
runs on the gate host and reads the real step text.
