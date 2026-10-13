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

Each started slot is handed the head it was started for, as one line of
`~/gate-runner/cache/wake-dispatch` (`<owner/repo> <number|-> <sha|-> <source> <when|->`). The runner
takes one line per tick and gates that head first of the pull-request heads its own pass found --
merge-queue entries still come first, each being one gate from landing -- and dates the queue wait
from `<when>`. The line decides nothing else: the tick still lists, chooses, claims and gates heads
by the ordinary rules, which is what keeps the slot timers a sufficient fallback. A line nobody takes,
or one older than `GATE_RUNNER_DISPATCH_TTL` seconds (default 600), is dropped unread.

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
`bin/pr-gate-*.sh` and `systemd/pr-gate-*.{service,timer}` there with the installed copies. A change to
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
