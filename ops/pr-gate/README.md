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
  existed, so nothing pointed a slot at it and it waited for a timer. A head the signal already woke
  a slot for is not woken for twice.

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
tree, recipe and slot environment as pull-request gates, then posts `<repo>/main-health` on that main
commit. That context is deliberately distinct from `<repo>/required`, so it cannot satisfy branch
protection for a pull request. A scheduled pass skips a repository whose main SHA already has this
runner's latest green main-health status; `--main-health --repo owner/name` runs that repository on
demand. If `GATE_RUNNER_RELEASE_GUARD_FILE` names an existing file, main-health exits quietly so it
does not compete with a release.

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

## Site configuration

Nothing in this directory names a site. Everything that does -- the forge URL, the credential file,
the gate identity, the owners and where their checkouts live, repositories with an unusual required
context or special build needs, where the installer fetches from -- is read at run time from

    ${PR_GATE_CONFIG:-~/.config/jeryu/pr-gate.env}

as `KEY=VALUE` lines. The file is data: it is never `source`d, only `PR_GATE_*`, `GATE_RUNNER_*`,
`GATE_INSTALL_*` and `JERYU_*` keys are taken, and a value already set in the environment wins, so a
unit's `Environment=` line or a per-slot drop-in still overrides it. A required setting that is
missing stops the script with `<KEY> is not configured`. `pr-gate.env.example` lists every key.

The runner hashes the site file into each gate's input identity, as it does its own code: changing
the configuration re-gates open heads once, exactly like installing a new runner.

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

## Qualification

`bash tests/required.sh` runs the whole suite offline: the config reader, the attempt journal and
publication recovery, the complete runner against a fixture forge and real Git (including re-gate
requests), the mount-namespace selection, lock inheritance, heartbeat and event projection, waking,
retention, the locked-crate prefetch's source allowlist, the installer and the database refreshers.
Every fixture uses invented names (`acme`, `gate-a`, `example.test`); none reads the host's own site
file. The repository's `ops/ci/pr-ci.sh` runs it.
