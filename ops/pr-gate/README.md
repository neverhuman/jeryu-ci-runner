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

## Fast and full validation

For a head with a `required-fast` recipe, the runner reads the target branch's enforced contexts
from the forge's branch-protection API. A requirement for `<repo>/required` selects fast validation
followed by the complete `required` recipe. Only protection requiring `<repo>/fast` without the full
context selects fast validation alone. Branch names do not select a tier. An unavailable or malformed
protection response defers the head; it never activates fast-only validation. Repositories without
`required-fast` keep their existing recipe and context. Main-health continues to run the full recipe.

Fast validation publishes `<repo>/fast` before full validation starts. While it runs, the full
context keeps its newest conclusion: a success stays as `keep_green` keeps one through any
re-verification, and a failure stays red until the full tier runs again. A fast failure stops there
and marks the full context failed, without attaching a full evidence identity. `required-fast` is
bounded at 30 minutes and the full recipe at 3 hours. The locked-crate prefetch and the build-cache
seed run once per head, and only the head's last tier may publish the shared build cache. With the
30-minute prefetch that is 4 hours inside the slot unit's 5-hour `TimeoutStartSec`. A forge re-gate request is read once for the head, before either tier
runs, so it re-runs a failed full tier as well as the fast one. Fast receipts live under
`tiers/fast/` in the head's journal, protected by the same descendant lock as the full receipts.
Both tiers bind the source and environment inputs, with distinct recipe and context fields in their
identities. Reuse checks each identity separately, including the forge status creator for results
from another host. A fast digest cannot satisfy a full claim, even if posted under the full context.

Tiered heads prepare their tree before deciding reuse so both contexts and current protection are
checked. Their `tiered` marker prevents the single-context shortcut from skipping that work, and
`cache/tiered-repo-<owner>-<repo>` makes a green protected branch tip of a tiered repository wait
for its prepared tree instead of being skipped at listing time. A repository without the marker
keeps the listing-time skip. Only a main-health tree without `required-fast` removes the marker, so
an old branch or a PR that drops the recipe does not switch it off for the repository. A head's
`tiered` marker counts only while its repository's is present. The fast context is `<repo>/fast`
named from the repository, also where `PR_GATE_CONTEXT_OVERRIDES` moves `<repo>/required`.
Publication recovery retains each tier's receipts and handles them before that tier can run again.

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

One cache per repository is shared by every slot, in `GATE_RUNNER_BUILD_CACHE_STORE`
(default `<runner home>/build-cache/<owner>/<repo>`): a `current` file naming a published version
and its cache key, and the versions themselves. When a gate's cache key matches `current`, the
runner copies that version into the slot's physical `target/build-cache` before the recipe runs
(a parallel copy that keeps mtimes, never a link, so the gate cannot write into the published
version; 2-5s for a 3.5-4.4G cache read from disk on a loaded gate host). When the gate ends
the slot's copy is either published or deleted; no slot keeps a cache between gates, so the disk
holds one cache per repository plus one per busy slot.

Only a green **merge-queue** gate or a green **main-health** gate publishes: commits that are
approved and landing on main. A pull-request head is unreviewed until it is queued, so it reads the
shared cache and never writes it. Contributions get a clean target and no cache variable, and the
store lives outside the slot tree a sandbox sees. Publishing is a rename onto the store's filesystem
and an atomic replacement of `current`; older versions are pruned unless a gate is still copying
them (each version has a lock a reader holds while copying). The key binds what cargo cannot see for itself:
compiler and tool bytes, host packages, governed tools, this runner's code, the execution kind, and
the gated checkout's `.cargo/` and `rust-toolchain[.toml]` (cargo `[env]` reaches build scripts that
may not declare `rerun-if-env-changed`). Sources, siblings, `Cargo.toml`, `Cargo.lock` and recipe
files are left to cargo's freshness check: the runner stamps every tracked file on checkout, so
workspace and sibling crates rebuild and dependencies are reused. Inputs without the tool identity
get no key. A gate whose key matches no version builds cold. The cache is for cargo's own output
only; a recipe must not keep anything else in `JERYU_CI_BUILD_CACHE_DIR`, which it also receives
with `CARGO_INCREMENTAL=0`, and should refuse any value other than its checkout's physical
`target/build-cache`.

A cache only grows (cargo never evicts, and the lock is not in the key), so a version larger than
`GATE_RUNNER_BUILD_CACHE_MAX_MB` (default 12288) is not published and `current` is withdrawn: the
next landing gate builds cold and publishes a fresh cache.

The store is not a boundary against an internal recipe: internal gates run as the gate user, who
can write the store, the sccache directory and this runner's state. What the publication rule
controls is which outputs the runner itself promotes to every slot.

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
takes one line per tick -- a main-health pass from `cache/wake-main-dispatch` instead, so the two
never take each other's lines -- and dates the queue wait from `<when>`. Its pass picks candidates
in this order: merge-queue entries first, each being one gate from landing; then explicitly
requested re-gates; then the woken head; then the other pull-request heads. A woken head therefore
never jumps ahead of a re-gate someone asked for. A candidate that cannot start (for example its
repository or head is already claimed or busy) is skipped cheaply and does not stop the pass: later
candidates are still tried in order. The line decides nothing else: the tick still lists, chooses,
claims and gates heads by the ordinary rules, which is what keeps the slot timers a sufficient
fallback. Hints survive busy slots and failed service starts for the next scheduled tick (normally
20–25 seconds after a slot finishes). Saving hints happens before acknowledging the signal or
updating the observed PR view; a failed write leaves that view available to retry. The file keeps
at most the newest 64 hints. Dated hints older than `GATE_RUNNER_DISPATCH_TTL` seconds (default
600) are dropped when read.
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

## Proving a pull request against its own base

A recipe compares the head against a proof base that defaults to `origin/main`, and a release line
does not descend from `main`, so every pull request into one failed its gate within seconds. When the
site names that recipe variable for an owner (`PR_GATE_PROOF_BASE_VARS=owner=VARIABLE`), the runner
sets it for every pull-request and merge-queue gate of that owner:

- a base the forge reports as protected (`GET /api/v1/repos/<owner>%2F<repo>/refs`, whose rows carry
  `{name, sha, kind, protected}`), or the repository's default branch, is proved against as
  `origin/<base>`, fetched into the gate tree at exactly the sha the forge reported. On a jeryu forge
  a branch is protected only when an administrator set a rule for exactly that branch name (rules are
  keyed by owner, repository and exact branch; there are no pattern rules), so an author cannot make a
  branch of their own protected by naming it;
- any other base -- a branch anybody with push access could create -- is proved against `origin/main`
  as before, and the status says why (`proof base origin/main (<base> is not a protected branch)`);
  so does a forge without the ref listing (404);
- a merge-queue entry uses the `base` its entry reports (jeryu-deploy `merge_queue.rs`), and only a
  forge that omits it falls back to the documented ref shape `refs/queue/<base>/<n>`; listing and
  admission derive it the same way, so the entry is admitted for the base it was listed with;
- a commit that is the head of more than one open pull request is proved against `main`, the
  default branch, whatever their bases, and its status says so (`proved against main: this commit is
  open in N PRs`). The forge keys `<repo>/required` by commit, so one result answers for all of those
  pull requests, and only a proof against `main` means what `main`'s protection assumes. A pull
  request whose head is its own keeps its release base. Binding the base into the status the forge
  reads, so one commit can carry a result per base, is a forge-side follow-up.

The ref listing is read as one answer: jeryu serves it unpaginated (`repo_refs` in jeryu-deploy),
and only rows with `kind: "branch"` count. A configured owner costs two more forge reads per open
pull request per tick (the head's status and, once per repository, the ref listing) and one ref
listing per gated head. `--list` lines gained a base field before the ready-at field
(`owner repo number sha queue-ref contributed base ready`).

The base is part of the result. Its variable, name and resolved sha are in the input identity
(`proof_base` in `gate_input_render`), so a moved base is a changed input. A base other than `main`
also has its own attempt and claim-lock key (`<owner>-<repo>-<sha>.base-<name digest>-<base sha>`,
`gate_attempt_key`); `main` keeps the historical `<owner>-<repo>-<sha>`, so existing journals and
recovery obligations stay where they are. A head proved against a release line is therefore never
reused or adopted for `main`, or the other way round, and every status that names a base other than
`main` says so (`; proof base origin/<base>`). Before a head is gated under one key, its unpublished
attempts under any other key (its base moved, or it was retargeted) are discharged: each receipt is
marked superseded by the new key, with no recovery owed, and kept as evidence; such a result is never
published or republished. A key another slot holds means that head is being gated there, and it is
left for the next tick. One head can collect an attempt directory per base commit it was proved
against; size the gate host's attempt store for that before enabling a busy release line.

The required status itself is still one context keyed by commit, which the forge reads without
knowing the base. So a retarget is handled as early as the runner can see it: each tick's listing
compares the newest own success on every open head of a configured owner (contributions included,
since this runs nothing of them) with the base that head would be proved against now, and posts
`pending` over one proved against another base before any tree is prepared; keep-green refuses it too,
and a pull request whose base changes between listing and admission is left for the next tick.
`--list` reads only and retires nothing. A contribution is retired too, since that runs nothing of
it; one no longer allowed to run then stays `pending` until a maintainer allows it again. A retargeted head can therefore show its old base's green
until the first tick that can read its status and its base from the forge: normally seconds, as the
retarget wakes a slot, but as long as the forge fails those reads. A refused `pending` is logged and
never ends the tick. Binding the base into the status the forge reads would close that window
entirely; that needs the forge, not this runner.

Binding `main`'s sha is a deliberate cost: for a configured owner, every merge to a repository's
`main` changes the inputs of every open pull request into `main` of that repository, which is then
gated again (subject to the usual coalescing, `GATE_RUNNER_REGATE_SETTLE`). That is the price of a
result that names the base it was proved against; owners without an entry are unaffected.

What a head changes about its own gate (the self-gate annotation, a contribution's gate-input paths)
is still read against protected `main`, whatever its proof base: the review signal never depends on a
base the pull request names. On a release line that diverged from `main` it therefore flags more than
the pull request's own change, which errs towards review.

A base the forge cannot answer for right now (a 5xx, a 429, a fetch that fails, a base that moved since
it was resolved) is not a verdict on the head: it is left for the next tick with no status posted, and
counted in `cache/proof-base-wait/`. Only the sixth tick in a row posts a failure, once, saying why. The
count is cleared by any tick that gets the base (fetched, or an unchanged head reused or held on inputs
that bind it), so a stale count never turns one later blip into a red status. A rate limit (429,
including this identity's own back-off) is waited out and never counted. For `main` the sha bound is
the one `sync_repo` put in the tree, so another slot advancing the shared mirror meanwhile is not a
failure. A malformed entry in
`PR_GATE_PROOF_BASE_VARS` leaves that owner on the recipe's own default and says so on every tick; a
variable that is also in `PR_GATE_WORKER_ROOT_VARS` is refused at start. Owners without an entry, and
main-health, are unchanged.

Roll a runner with this out to every gate host before adding the setting: a host without it proves a
release-line head against `origin/main`, its identity differs, and the two hosts would overwrite each
other's verdict on that head every tick.

## Gating a protected branch's tip

A commit that reached a release line without a green gate (merged before release-line PRs could be
proved at all, say) never gets a hosted `<repo>/required`, and promotion needs one. Pull-request gates
see only open heads and `--main-health` only `main`, so

    pr-gate-runner.sh --branch <name> [--repo owner/name]

gates the current tip of `<name>`:

- only a branch the forge reports as protected (`GET /api/v1/repos/<owner>%2F<repo>/refs`), of an
  owner with a `PR_GATE_PROOF_BASE_VARS` entry; anything else -- unprotected, missing, a forge that
  cannot answer, an owner whose recipe cannot be told the base -- is refused and named, and with
  `--repo` the run exits 1. Nothing is posted on a refused branch;
- `--branch main` is the supported retry of a protected main tip whose latest `<repo>/required` is an
  error (a merged pull request's revalidation that returned `inputs_changed`, say; a merged or closed
  PR is never listed, so `--pr` cannot select it). It needs no `PR_GATE_PROOF_BASE_VARS` entry: the
  recipe keeps its own baseline, protected `origin/main` in the prepared tree, and nothing a caller
  or a PR controls is passed. The tree's `origin/main` must equal the tip observed and admitted, or
  the run leaves it for the next tick; the other rules below (own work, never over a green) apply;
- never the runner's own work: a branch named `<gate identity>/...`, or a tip authored or committed
  as the gate identity (the forge does not say who pushed a tip; a protected branch moves by merge),
  is refused;
- never over an existing green: a tip that already carries this runner's `<repo>/required` success (a
  pull-request or merge-queue gate, or an earlier pass) is skipped, because that green was proved
  against the base its own gate used;
- with the repository's own recipe (`just required`, else `ops/ci/pr-ci.sh`) in the usual family tree,
  proved against the branch as it stood before the tip: the proof-base variable is `origin/<name>~1`,
  the tip's first parent on the protected branch's own history -- what the pull request that made the
  tip was proved against. Proved against the tip itself, every base-relative check would see an empty
  diff. A root commit has no base and is refused;
- posting `<repo>/required` on the tip commit as the gate identity, with
  `; proof base origin/<name> before this commit (<parent>)` in its description; the self-gate
  annotation is computed against protected `main`, as for pull requests;
- under the same evidence identity and reuse rules as pull requests: the base and its resolved sha are
  in the inputs and the attempt key, and a failure is held. `--repo` makes the run a retry, as
  `--main-health --repo` is. The tip is re-read before the recipe runs, and a tip that moved is left
  for the next run.

It takes no wake-up line, reads no merge queue or re-gate requests, never publishes the shared build
cache, and has no timer: an operator or a release step runs it. `--pr` and `--main-health` are other
modes and are refused with it.

## Release preflight

`pr-gate-runner.sh --preflight` (ADR 0019) is a read-only look before a release. It takes no slot lock,
writes and posts nothing, and stops asking the forge after `PR_GATE_PREFLIGHT_BUDGET` seconds (default 90).
It reports `.git/index.lock` files older than `PR_GATE_PREFLIGHT_LOCK_AGE_MIN` (default 120 min) under the
slot trees; tools in `PR_GATE_PINNED_TOOLS_FILE` (`name package version[,version] [sha256]`) that are
missing, carry another digest, or whose installed dpkg version is not a reviewed one; and each family
main's latest `<repo>/required` status. Exit 0: clean; 1: findings; 2: misconfigured.

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
main-health is its own far-apart timer. That memory is one file per repository, and the woken slot is
handed the repository in `cache/wake-main-dispatch` (`<owner/repo> - - push <when|->`), which the
main-health pass takes one line of and gates first of its candidates: a pass builds candidates across
every gated repository and gates one of them, so a single host-wide bit let a pass that gated another
repository forget a push nothing had looked at. A repository's kept push is dropped only once a slot
has been started for it. A red main SHA is gated again on the next pass (only a green
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

The schedule is the site's to choose: set `PR_GATE_MAIN_HEALTH_SCHEDULE` in the installer's
`pr-gate.env` to one or more systemd `OnCalendar` expressions separated by `;`
(`*-*-* 03:30:00; *-*-* 15:30:00`). `pr-gate-install.sh` writes them to the drop-in
`pr-gate-main-health@.timer.d/schedule.conf`, reloads systemd and restarts the active
main-health timers; unset, the template's nightly 03:30 applies and a drop-in the installer wrote is
removed. A value that is not plain calendar text, or that `systemd-analyze calendar` rejects, changes
nothing, and a drop-in the operator wrote themselves is never replaced. Today's single tier
(`required`) is what each scheduled pass runs; a fast tier is a further expression here once it exists.

A red main is reported by the forge as itself, not as a failure on a change: the runner posts the
red `<repo>/main-health` status on the main commit, and jeryu raises the `main_red` item on
`/needs-you` from it (jeryu-deploy: `main_red_items`), naming the first failing step.

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
   `GATE_RUNNER_OWNERS`, as the slots and the wake timer choose them). Bound tickets follow the
   admission contract below. For unbound tickets, admit only reviewed code: a
   job for `main` whose head the clone's own `main` reaches (the ticket's word is not enough), or the
   head of an open pull request the forge marks `origin:internal` (`PR_GATE_INTERNAL_LABEL`; every page
   of open pull requests is read, and a label may sit on the row or under its summary). A contribution (`origin:contributed`), a head no open
   pull request holds, or a forge that cannot answer is left alone -- like the slots, this host checks
   out nothing of a contribution. A job left alone is not refused on the forge (there is no route for
   that on the unbound contract); its claim lapses with its lease;
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
  (`capabilities: {jankurai: [...], sandbox: <configured>}`) and what the heartbeat's `tools` lists. No
  release-specific verifier is involved, so an auditor release reaches this host without a pr-gate or
  consumer change.
- **Admission follows the ticket**, including personal-agent heads absent from local discovery.
  Contributed jobs use `PR_GATE_SANDBOX_COMMAND` with the same tree-root/repo/argv contract as
  contributed recipes, an empty host environment and a digest-checked copy of the assigned auditor.
  The sandbox must expose only that disposable tree and supply the auditor runtime. Without a
  resolvable command, the claim advertises `sandbox: false` and contributions are handed back.
  See the [ADR 0003 addendum](../../docs/adr/0003-audit-admission-addendum.md) for the boundary and
  fixture proof; the live host probe is a separate owner step.
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

### Dirty input capture diagnostics

A dirty checkout still yields `inputs_changed` with the recipe's original exit code and the
same rerun limits. The attempt log names the checkout and records its first 20 raw Git porcelain
lines. Those operator-only lines are never copied into a public status or check title.

The optional `input_capture_error` receipt object stores a verified `repository` label,
`porcelain` (at most 20 allowlisted entries), and `omitted` (the count withheld from those 20).
Repository labels must match the canonical hosted origin and contain only the bounded owner/repo
charset. Contributed/sandbox runs withhold all runtime checkout identities and paths, including their
own: even an allowlisted filename could encode private input. Unverified checkout identities are also
withheld. The operator log retains the raw details; other capture errors remain in the runner journal.
Recording this optional diagnostic is best effort and cannot abort normal rerun accounting or publication.

The required-status description and check summary name validated paths from those first 20 lines:
ASCII Git status codes plus relative paths using letters, digits, `_`, `.`, `/`, or `-` (and the
literal rename separator ` -> `), at most 80 bytes per entry. Other entries are withheld and counted
in the public diagnostic. Typechange (`T`) status entries are included. Publication
revalidates the receipt, including on recovery. The public diagnostic is below 2048 bytes and cannot
contain a semicolon or newline, so it cannot inject a status metadata field. The check title remains
a short verdict referring readers to the status and attempt log; it never embeds the path list.

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

Passing recipes whose execution inputs change produce a neutral check run with a
passed-with-changed-inputs explanation; completed steps remain green. The receipt
retains the observed after-input identity and names repository head changes. The
required status is `error` (the result proves nothing about the head). The invocation
ends as after any result, so one unit run never holds more than one recipe. The next
tick re-runs that head ahead of the heads that already hold a result, once the
family's mains have settled (`GATE_RUNNER_REGATE_SETTLE`, as for any re-gate); the
re-run posts its own `pending` when it starts. On a scheduled pull-request pass, after
two consecutive automatic re-runs the head is held until an explicit re-gate: a forge
re-gate request or `--repo <o>/<r> --pr <n>` starts a new bounded chain. `--branch`,
`--main-health` and merge-queue gates have no such request, so they are never held
and re-run on each pass. The chain counter lives in the receipt and survives tick
restarts; an unreadable `last-result.json` counts as no chain.

Sibling sources already run from the slot checkouts selected during preparation.
A remote main moving alone does not change those checked-out inputs during a run.
The runner still verifies every executed checkout and tool after the recipe; it
does not accept mutations to siblings as proof of the original snapshot.
