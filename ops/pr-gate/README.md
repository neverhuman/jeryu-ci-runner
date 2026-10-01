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
| `bin/pr-gate-wake.sh` | starts an idle slot as soon as a gated head appears or moves |
| `bin/pr-gate-install.sh` | keeps the installed copy equal to the source branch (drains slots first) |
| `bin/pr-gate-advisory-refresh.sh`, `bin/pr-gate-grype-db-refresh.sh` | keep security databases fresh outside the gates |
| `systemd/` | the `--user` units and timers; `pr-gate-runner@N` is one slot |
| `tests/` | the offline regression suite (`tests/required.sh`) |
| `VERSION` | the component's own version |
| `pr-gate.env.example` | every site setting, with invented values |

On a gate host the scripts live in `~/gate-runner/bin`, the units in `~/.config/systemd/user`, and
the state under `~/gate-runner` (`installed-main.json`, `tools.json`, `attempts/`, `cache/`, mirrors
and trees). The units run `%h/gate-runner/bin/<script>`.

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
  unit names or state files changed, the heartbeat/status/receipt shape changed.

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
publication recovery, the complete runner against a fixture forge and real Git, the mount-namespace
selection, lock inheritance, heartbeat and event projection, waking, retention, the locked-crate
prefetch's source allowlist, the installer and the database refreshers. Every fixture uses invented
names (`acme`, `gate-a`, `example.test`); none reads the host's own site file. The repository's
`ops/ci/pr-ci.sh` runs it.
