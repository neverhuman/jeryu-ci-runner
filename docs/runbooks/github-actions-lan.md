# Shared LAN GitHub Actions rollout

Owner: the operator executing the neverhuman CI migration. Updated 2026-10-04.

## Objective and current qualification

Keep extra GitHub processing charges at $0 and run CI on xbabe1, xbabe2 and
xbabe3 through shared organization runners. Preserve required checks, source
authority, release evidence and platform coverage. Never treat a missing runner,
cancelled run, skipped lane or local-only success as a green required check.

The owner browser currently confirms standard hosted runners disabled, zero
configured larger runners, $0 Actions billed, and $0 stop-usage budgets for
Actions, Packages, Codespaces, Git LFS, Sandbox and all AI Credit SKUs. The latter
organization-scope budget caps additional AI usage while the UI distinguishes
included allowances from additional usage. Its saved $0/Stop usage Yes row was
verified at 03:24 UTC October 5. Sandbox also has a saved $0 hard stop.
All six organization rows were re-read at 03:55 UTC with $0 budgets and
Stop usage Yes. The standard hosted disable policy was re-read at 03:56 UTC.
Models budget creation reports paid usage disabled; no paid usage was enabled.
The Models policy link returned 404, so it is not a policy-page verification.
Spark budget creation remains disabled after a zero input; no budget or paid
service was enabled. Advanced Security is license-based and its UI explicitly
does not support Stop usage; an alert-only budget would not enforce this goal.
The Team subscription is separate.
External fork workflows require approval from all outside collaborators. Shared
group `neverhuman-lan` is ID 3. Admission is staged by repository; this is one
shared pool, with no repository-owned VM/controller. Each VM passed the runner/Docker, GitHub and
forge HTTPS, LAN/metadata/public SSH denial and credential-absence checks in
`qualify.sh`. These are infrastructure proofs, not repository CI passes.

Owner authentication is complete. Private org App
`neverhuman-lan-runner-controller` (App 5190166, installation 167953338) has only
organization Self-hosted runners read/write, no repository access and no webhook.
Two boot-enabled lanes on xbabe1/2 and four on xbabe3 automatically create and
destroy single-job VMs. Seven lanes serve Ubuntu 24.04/browser158; lane 2 on
xbabe3 serves Ubuntu 26.04. Measured memory/disk admission allowed lane 2 on xbabe1/2
without stopping existing work. Each guest uses 8 vCPUs/8 GiB and a bounded overlay. App credentials are root-only;
the downloaded local key copy was removed and both unusable keys were revoked.

Infrastructure probe run 37237247647, attempt 1, exact source
`64f14dbf74489fa068df3fa8a2a58fb5f45f5ccf`, passed all nine jobs. Six initial
jobs and three replacement jobs covered all three physical hosts. Replacement
IDs 260, 261 and 262 are bound to root receipts, image hashes, VM stop and
workspace destruction. Bootstrap IDs 254–256 were also consumed, unregistered
and their stopped VM disks removed. GitHub Actions on this static mirror was
enabled solely for that diagnostic, then restored to disabled. This does not
qualify `jeryu-ci-runner/required` or make GitHub the source authority.

Demo PR 2 https://github.com/neverhuman/demo-repository/pull/2 passed Proof
HTML 37240262374 and Auto Assign 37240360294 at exact head
`01e19535744ed869f06dc77fa7f2703c613df8f1`. The existing v1 assignment defect was
repaired with pinned github-script v8 while preserving issue/PR triggers and
assignee intent. PR 1 was superseded. PR 2 merged at 22:46 UTC as
`58680da2edf7d9969b126c0a669449bfe142ce35`; post-merge Proof HTML
37241297010 passed on the shared pool.

Dope PR 108 https://github.com/neverhuman/dope/pull/108 passed CPU/security
37239693821 and Full Jankurai 37239693742 at exact head
`7f75ba398d7076be4051bcacb1970b21a34d70e2`. It merged as
`55995d00ffd7f9d4435b549e32350dde508577bd`. Post-merge CPU/security
37241411624 and Full Jankurai 37241411579 both passed.
Dope's GPU workflow still requests a local GPU capability. Fresh repository runner enumeration found zero registered dedicated GPU runners; shared GPU execution remains unqualified.
The credential-free local `just check` VM also passed and was destroyed.

Application PR 250 https://github.com/neverhuman/ai-veox-app/pull/250 landed
through the unmodified `just land` recipe onto `rc/auto` at 23:24 UTC, exact head
`550f9db55a73bb2356bd41a5fa60311910612ca1`. Full `just required` passed in an
owned credential-free LAN VM; actual PostgreSQL/browser CI 37242647163 passed
on runner 284 on xbabe1. Both are necessary proof; the local lane without a DB
is not a replacement for database CI. Its first full local gate discovered that
the convoy lacked published v0.8.10/v0.8.11 release notes; those exact entries
were restored from tag v0.8.11 (`fa808afec43e547e823016090fac17f95ad91fc2`). CI
now fetches tags to enforce the same check. Earlier cancelled/superseded runs
are not passes. Main promotion PR 251 initially contained only the already-landed CI files,
head `d816c2bd489b477173bf2fa93638dffb4adeb22e`; its own final-head run
37243774021 failed both attempts: observability.rs:492 assumed one day across
UTC midnight; load.rs:226 backdated fixtures into the preceding UTC day.
Retain both failures. Post-convoy run 37243633840 passed. Fixture-only repair
convoy PR 252 initially at `ce5e78f0e204644b7cc99a8ca0d7e9f9e0a8ed30` deliberately crosses
midnight and asserts both observation days, while the count fixtures remain on
their intended UTC day. Full local `just required` and both actual PostgreSQL
cases passed in an owned disposable LAN VM; that VM was destroyed. Actual full
PostgreSQL/browser CI 37248250631 also passed both fixture cases, then timed out
at the unchanged 30-minute quota; browser integration was skipped and the
unmodified `just land` refused to advance the convoy. Current head
`ecf35a8a6e172b8963a0e8ce37a1473bed775dc6` adds a bounded 2 GiB tmpfs for the
disposable PostgreSQL 16 data. Default fsync, synchronous commit and full page
writes remain enabled. Full CI 37250577186 and a fresh exact-head local gate
passed; the unmodified `just land` advanced `rc/auto`. Post-convoy 37251057764
passed. Main PR 251 promoted both repairs at exact head
`9644855b355526cd84b22f5b4ac2d4458292d066`. Run 37251123099 attempt 1 failed
an upstream Cargo HTTP/2 download before tests; the unchanged attempt 2 passed.
Ordinary merge produced `5c6ec7ed1dee8a864ee32bd6da503bba7da0da27` at 01:41 UTC
on October 5. Post-main 37252384703 passed with actual PostgreSQL and browser
coverage. No production release tag was created.

Jailgun PR 20 https://github.com/neverhuman/jailgun/pull/20, final head
`607f408e90adda98b57a43eb4285ab19ab176ee7`, preserves both actual Ubuntu
24.04 and 26.04 matrix children. Pre-merge runs were 37252875495 (CI),
37252875560 (Jankurai) and 37252875459 (Security). All 16 jobs passed,
including both real native package children, standalone e2e and the dependent
aggregate. Both audit reports are 95 with zero findings/caps. Exact runner IDs
bind all 16 successful jobs to root exit-0, stopped/destroyed guest receipts.
The verified tree was squash-merged as
`042f1e10f1b32c43da82482fe0b70e839c02d162` at 03:00:44 UTC on October 5.
Post-merge runs 37257660321 (CI), 37257660201 (Jankurai) and 37257660161
(Security) passed all 16 jobs. Both native package/runtime children and all three
cancellation barriers bind the actual main commit and matching driver hash;
both audit reports score 95 with zero findings/caps. The first main CI attempt
exceeded the unchanged 180-second database subprocess bound and did not emit
the captured child log. That failure remains retained; its cause is not proven.
One failed-job-only retry on the same commit passed all 34 database tests with
SQLite 3.53.2 (36.81 seconds compilation, 6.33 seconds tests), then passed the
dependent aggregate. CI attempt 2 retains 12 successful executions from attempt
1; only database and aggregate executed again. API history binds retained jobs
to their original execution IDs/times rather than counting them as new work.
The complete post-main run and root exit-0/destroyed-workspace receipts passed
verification at 04:06 UTC. No test, timeout or source changed for the retry.
The preceding d833 head passed both native package children, Security and
Jankurai (95, zero findings/caps), but standalone e2e failed because its
synthetic cancellation victim could finish while waiting for a separate main
run. The dependent aggregate was skipped. The CI-owned
`scripts/check-concept-workflows.mjs` now holds only that victim in the existing
partial mode before conversation publication and requires every held victim
to be stopped. Rust ownership, double-cancellation, capacity release and
partial-artifact assertions remain intact. No product implementation changed.
The new head has its own complete audit, native and end-to-end receipts;
the previous head's failures remain historical evidence.
Full CI still requires both platform children, end-to-end and the aggregate.
At the preceding head, Security passed and both real OS guests launched sandboxed
Chromium. Copy-code and Jankurai failed because cargo-installed binaries were not
on the next step's PATH. A dynamic GITHUB_PATH write then correctly failed the
security scanner; common setup now writes the verified guest's literal
`/home/runner/.cargo/bin`. Actual pinned Security passed without a github-env
exception. All final-head gates subsequently passed with the original thresholds.
The first head failed because Playwright 1.60 has no Ubuntu 26 dependency
installer entry and zizmor flagged all 15 self-hosted jobs. The repair installs
the pinned Chromium native library list from the real Ubuntu guest repositories,
then requires an actual sandboxed browser launch. Per-job zizmor exceptions cover
only the self-hosted-runner rule and document the disposable KVM boundary; no
scanner command or other rule is disabled. Old failed/cancelled runs are retained. Source setup installs distro
just/rustup. `ops/ci/lan-browser.sh` extracts the digest-pinned public Playwright
1.60 artifact, installs dependencies and requires a real sandboxed browser launch;
it refuses non-VM hosts and changes user-namespace policy only in that guest.
The unchanged package doctor uses standard absolute browser locations. The
preceding Ubuntu 26 package gate failed to discover the extracted executable;
guest preparation now exposes that same qualified browser at `/usr/bin/chromium`
and verifies its target/version, refusing to replace any different browser.
Installed-package, actual user-systemd and browser-absent clean-container
acceptance remain required; no package assertion is changed.
No scanner/auditor floor, native acceptance proof or timeout was removed.
Group admission contains demo-repository, ai-veox-app, dope and jailgun
(numeric IDs 1388268629, 1336448620, 1394151792 and 1254916854), all workflows,
with public-repository access enabled under the verified VM boundary.

CI-kit 1.4.1 includes immutable browser/Ubuntu capabilities and lanes 1–4. All three
`runner-ubuntu24-x64-browser158.qcow2` images passed full browser launch,
credential-absence and network-isolation checks. Factory builds use a fresh,
unregistered guest from the pinned base, never an Actions job disk. xbabe1/2
used the public linux/amd64 artifact
`mcr.microsoft.com/playwright/python@sha256:cd8493e380df200a471821e2690b710eab8d793dde3c0946fd0a39a961022914`;
xbabe3 used the normal pinned Playwright installer. Image hash, prepared receipt
and qualification receipt must all match before `launch.sh` publishes browser158.
Root unit drop-ins select this profile on the next automatic job cycle, preserving
active jobs. Host images, exact hashes and qualification receipts are in the
operator's `neverhuman-browser-image-proof-2026-10-04.json`.

The fresh Actions-policy audit found 24 live workflow files in seven active
repositories: jailgun, ai-veox-app, bullet-kernel, JopeDime, demo-repository,
redline and dope. The initial 46 definitions also include GitHub-disabled static
mirrors. Keep their local-forge source authority and disabled GitHub Actions;
do not enable duplicate CI to inflate migration counts. Demo, Dope Linux,
application main and Jailgun migrations have landed with post-merge proof. Full platform
migration remains incomplete. Old hosted-label jobs are queued behind the disabled
policy. Existing local product runners remain until their replacements qualify.

Selected product receipts now cover 49 successful executions in 21 successful
workflow runs across all three physical hosts. Live root verification found all
49 exact per-job VM units stopped, their main/control PIDs zero, and generated
disk/seed files absent. Two earlier manual cleanup recoveries still retain the
original controller exit 2; they are not relabeled automatic cleanup passes.
The 04:02 UTC current-main routing readback covers nine workflow files and 21
shared-group job selectors, with no hosted fallback in migrated files. Dope's
later main `66131fd8a42f771c7c26ca98c2ca23c8e115e4a4` retains the routing;
inspection alone does not qualify that later product head. Its GPU workflow
remains a local capability exception pending shared GPU isolation/corpus proof.

Ubuntu 26.04 source is the official 20260927 cloud image, SHA256
`8800651811af9a85465ad1d552add729947bb16488dddb4a9b5305a3d97332b2`.
The immutable xbabe3 guest image is
`60f15a2489649258c7b177ff6a1a99131c7bc4f3884a73d6ec5c173eb3dca7e7`.
Its OS, runner, Docker, network and credential boundary qualification passed
and the qualification guest was destroyed. All three browser158 qualifications
now also bind the actual Ubuntu 24.04 version. Admission refused both a
mismatched image receipt and a wrong OS label before VM/JIT creation. A separate
`neverhuman-runner@2.service.d/ubuntu26.conf` selects this capability in the same
general group; it does not dedicate a runner to Jailgun.

Cache audit `neverhuman-cache-limit-audit-2026-10-04.json` read all 41 repository
storage limits successfully: each is 10 GB. The org eviction setting is also
10 GB. Eviction is not a spending guarantee; the $0 Actions stop-usage budget
is the billing control. The 03:55 UTC October 5 owner-browser readback reports
$0 Actions billable, $108.87 gross usage fully offset by $108.87 discounts,
0 private hosted minutes and 0.5 GB of the included 2 GB storage. The existing
three-seat GitHub Team subscription remains $12/month. Delayed storage billing
after the final migration window has not yet been verified.
Billing storage reporting lags; a later post-rollout readback is still required.
Gross Actions usage is now $108.86 and is fully offset by $108.86 discounts.
Every observed compute/storage SKU has $0 billed; the historical public compute
usage and a small continuing storage amount must not be mistaken for a charge.

## Assumptions, dependencies and non-goals

- All three hosts are Ubuntu 24.04 x86_64 with KVM and existing production work.
  Local SSH aliases use ubuntu at 162.218.217.123 ports 696, 6969 and 6970.
  Verify `hostname -s` on each connection; aliases on remote hosts can differ.
- Use existing capacity and protected source/tool authorities. No cloud compute,
  paid GitHub larger runners, hardware purchase, disk reformat, dependency source
  rewrite, audit-policy relaxation or replacement of a required check with a
  status written by the operator.
- A GitHub App with only organization Self-hosted runners read/write is required
  for JIT replenishment. Its private key and metadata must be root-owned 0600 in
  `/etc/neverhuman-actions/`; neither enters a VM, Git, log or evidence attachment.
  The owner explicitly authorized the operator to drive Chrome/SSH, perform the
  entire migration and make all key decisions. No additional routine choice or
  implementation approval is pending. An actual login/access challenge remains
  a technical stop for that action, not authorization to bypass authentication.
- The current Linux-only fleet cannot satisfy native macOS jobs. Keep native
  macOS coverage blocked until suitable native hardware exists on the LAN; do
  not purchase hardware or claim full platform migration. Linux ARM jobs need an
  emulated ARM guest or validated cross-build/runtime alternative; Windows jobs
  need an available licensed guest and equivalent native proof. No silent matrix
  deletion, Linux relabeling as macOS/Windows/ARM, or hosted fallback.
- GPU and large CPU lanes are shared capability profiles, not repository-owned
  hosts. They require separate resource/device qualification. Initial pilot VMs
  use 8 vCPUs/8 GiB; do not assume this capacity qualifies every existing job.

## Read first and ownership

1. Root `AGENTS.md`, `README.md`, `agent/owner-map.json`, `agent/test-map.json`,
   `agent/generated-zones.toml`, `agent/proof-lanes.toml`,
   `agent/audit-policy.toml`, `agent/boundaries.toml`, then `ops/AGENTS.md`.
2. `ops/ci-kit/README.md`, `bin/{manifest,seal,vendor,verify}.sh`,
   `test/selftest.sh`; the new `github-actions/*.sh` and service units.
3. Each target repository's current instructions before editing its workflows.
   Redline requires bf claims, a canonical checkout and no Git worktrees. JopeDime
   requires its canonical `/home/ubuntu/JopeDime`, locked AGENT_CHAT entries and
   an independent exact-head review. Bullet requires its family manifest/log.
4. Jeryu's governed `jeryu-tool/tool-manifest.toml`, `ops/install-jankurai.sh` and
   the exact installation receipt requirements in `ops/ci/ensure-jankurai.sh`.
   The pinned browser capability is qualified. Rust/just/nextest/security tools
   and the governed auditor are not all baked into this VM image. Install through their authorities and qualify
   receipts; do not fabricate stamps or use diagnostic receipts in official CI.
5. Redline release permission/acceptance scripts and JopeDime runner provenance
   action before moving their release/large jobs. Label replacement alone is
   insufficient for either repository.

Write scopes: CI-kit source and this runbook belong to ops/docs. Per-repository
workflow changes belong to that repository's claimed ops scope. Generated
`ops/ci/kit/**`, kit pins/manifests and `.jankurai/**` are generator-owned. Never
manually edit vendor copies or audit outputs. Product Rust, Cargo identities,
source archives, host storage orchestrators, old runner credentials and existing
workspaces are outside this migration's write scope. A single operator owns
organization settings and host services. Concurrent workflow edits in the same
repository, Redline's hot CI file and shared kit version changes conflict.

## Ordered execution

1. Re-read billing budgets and Actions policy in the owner Chrome session.
   Record time, setting and budget values. Keep $0 Stop usage enabled. Check
   standard and larger runner paths; disabling standard labels alone does not
   forbid a paid larger runner exposed through a group.
2. Preserve the completed owner's GitHub access verification and private org-owned
   registration app with Self-hosted runners read/write only, no webhook,
   repository content/write, billing, deployment or review permissions. Confirm
   its narrow permissions by fresh readback. Put IDs in
   `/etc/neverhuman-actions/app.json` and its key in `app-key.pem` (root 0600).
   Validate `api.sh GET /orgs/neverhuman/actions/runners` without logging tokens.
3. From the exact reviewed CI-kit source, run `provision.sh --prepare` on each
   verified physical host. It installs only QEMU/cloud tooling, a dedicated
   `neverhuman-vm` uid, pinned cloud image and disabled controller units. Existing
   runner services and host firewall tables are preserved. Receipt/log roots:
   `/var/lib/neverhuman-actions/{receipts,jobs,images}`.
4. Run `egress.sh`, `prepare-image.sh` and `qualify.sh`. QEMU owns no host mount,
   Docker socket or API private key. Only its uid's egress is filtered. The
   controller connects through localhost SSH; the guest uses public DNS and
   cannot initiate LAN/metadata/host-SSH connections. Forge HTTPS is the sole
   explicit local service exception. Inspect logs and nft counters on failure.
5. Add the governed toolchain/auditor installation to a newly versioned base.
   Build and qualify the actual repository entrypoints in that guest. Keep the
   qualified base immutable and record its hash. An image or receipt change
   requires requalification; do not retag an existing image receipt in place.
6. Enable one JIT controller lane per host after credential and image checks.
   `launch.sh 1` creates a fresh VM, generates one JIT config in group 3, starts
   one job, stops the VM and removes only its generated disk/seed. The root
   receipt binds runner ID, actual physical host, image hash and timestamps.
   Add further lanes only after measured memory/disk/CPU admission. A successful runner
   process exit does not prove the GitHub job itself succeeded.
7. Review the live isolation receipts before each admission expansion. Grant shared
   repository access and keep all-external-contributor approval enabled. Restrict
   privileged release workflows to trusted refs through an additional shared
   release group/profile; test its refusal for PR and fork refs.
8. Migrate a small Linux-only repository first through its required PR/review
   process. Every compute job must use the explicit group/labels below. Keep
   reusable workflow calls as calls; migrate their compute jobs. Refresh source
   heads before editing. Verify an actual GHA job's runner ID against the root
   receipt; then verify scheduling on each physical host and runner replacement.

   ```yaml
   runs-on:
     group: neverhuman-lan
     labels: [self-hosted, Linux, X64, lan-ci, ubuntu24]
   ```

9. Batch the remaining Linux workflows by repository with disjoint claims. Audit
   all 38 active repositories, distinguish the 24 live workflow files from the
   initial 46 definitions, and trace their matrices/reusables;
   74 initial job definitions explicitly used hosted runners, 9 had dynamic
   routing and 2 were reusable calls. Check workflow_dispatch, schedules, release,
   workflow_run, fork and Dependabot triggers. Remove expression/matrix hosted
   fallbacks. Resolve `runner.os` assumptions, tool-cache paths, services, sudo,
   Docker, workspace cleanup, artifact expectations and cache trust namespaces.
10. Special cases: Redline's seven workflows include Linux x64/ARM, macOS Intel/
    ARM, reusable packaging, clean release attestations and PostgreSQL 16.15
    parity. Preserve exact acceptance evidence and publishing permissions.
    JopeDime's `ci.yml`, `full-main.yml`, `main-guard.yml`, `release.yml`,
    `runner-admission-probe.yml` and `weekly.yml` enforce script/image provenance
    and CPU exclusivity; replace that proof with an equivalent shared-profile
    proof, and run the deliberate admission rejection tests. Dope's GPU/corpus
    and Bullet's macOS/Windows refusal lanes need their actual capabilities.
    Jeryu-deploy's 40 shards must queue within shared admission limits.
11. Re-run each target's required commands and bind CI run ID/attempt to the exact
    PR head. Redline: `just fast`, then its required/pr-ci PostgreSQL lane;
    Jailgun: `bash ops/ci/scan.sh` and `bash ops/ci/jankurai.sh`; Bullet:
    `bash scripts/ci-local.sh required`; Jeryu family: canonical required entry;
    JopeDime: all eight manual lanes plus aggregate and post-merge main guard.
    Preserve independent reviewer requirements. Leave PRs open if checks or
    review cannot qualify. Never weaken protections to force a merge.
12. Drain old repository listeners only after replacement jobs pass. Resolve
    renamed/transferred repository IDs and actual ownership. Stop new listeners,
    wait for busy jobs, then disable/remove only confirmed replaced services.
    Do not kill an active job, reuse another repository's credentials or delete
    its checkout. Then disable new repository-level runner creation.
13. Verification: freshly enumerate workflow definitions and recent jobs across
    every active repository. For each completed job require an approved runner
    ID and matching controller receipt; inspect matrix children and called
    workflows. Require no hosted fallback, native capability coverage, required
    check passes, safe fork refusal, release isolation, replenishment after jobs,
    restart recovery and sufficient storage. Pending/skipped/cancelled is not pass.
14. Recheck billed Actions/storage after GitHub reporting catches up, and retain
    the zero-budget proof. Keep required artifact evidence inside included
    storage or migrate its lifecycle explicitly. Do not delete receipts to
    reduce storage without replacing the consumer's proof requirement.

## Validation and handoff

Run from the exact source checkout (prefix shell commands with `rtk`):

```sh
shellcheck -x -P SCRIPTDIR ops/ci-kit/github-actions/*.sh
bash ops/ci-kit/bin/seal.sh
bash ops/ci-kit/bin/vendor.sh .
bash ops/ci-kit/test/selftest.sh
bash ops/ci/kit/bin/verify.sh . --canonical ops/ci-kit
just required
```

The kit generators use GNU utilities; run them on Linux when the local Mac
lacks them. Do not hand-generate a vendor copy. Live host commands are root
`bash /opt/neverhuman-actions/{egress,prepare-image,qualify}.sh`; read the root
JSON receipts and unit logs. Scope SSH evidence to status, public binary hashes
and receipts, never `.credentials`, browser cookies or private keys.

Completion requires all required jobs running on admitted LAN capabilities,
all checks and exact-head reviews green, shared runner recovery proven, old
dedicated services retired, hosted execution unavailable and extra billed usage
still zero. Stop dependent activation on an owner auth/access challenge,
unresolved native platform support, unexpected source/claim conflicts, failed
isolation/provenance, missing independent review or failed required evidence.
Continue independent preparation while those conditions are pending.

Handoff must list settings changed, PRs/full heads, merged required check/run
URLs and attempts, runner-ID/host receipts, image/tool hashes, retired services,
billing timestamps, remaining exceptions and their owners. Report implemented,
locally verified and live-qualified states separately. Publish concise progress
updates during work; preserve a machine-readable status/evidence receipt.

## Exact work packets and dependencies

The operator owns execution and all implementation choices. These scopes are
sequential unless independent claims explicitly permit concurrent work. Org
policy, image releases, kit versioning, root credentials and host admission have
one writer. No parallel worker may edit those shared files or a target checkout
with an overlapping claim. Existing active JopeDime CI is not a drain opportunity.

Local staging root is
`/Users/bentaylor/Documents/Codex/2026-10-04/we/work/`; user receipts are under
the adjacent `outputs/`. Read `/Users/bentaylor/.codex/RTK.md` and prefix every
shell command with `rtk` (use `rtk proxy` for normal commands). Local Mac disk
headroom is insufficient for full Rust builds; execute them in an owned disposable
LAN guest, retain logs and stop/delete only that guest's generated overlay/seed.

1. **Controller source qualification.** Read the governed local-forge checkout
   `/home/ubuntu/jain-split/jeryu-split/jeryu-ci-runner` and parent family guidance
   on xbabe2 before making authoritative edits. The GitHub staging checkout is
   `work/github-sources/jeryu-ci-runner`, draft PR 1. Reconcile current protected
   forge head; never overwrite an older canonical checkout with the GitHub
   mirror. Edit only `ops/ci-kit/github-actions/{common,prepare-image,prepare-browser-image,
   prepare-ubuntu26-image,qualify,launch,api,egress,provision}.sh`, units and this runbook as needed. `api.sh`
   must keep its endpoint allowlist; do not turn it into an arbitrary privileged
   transport. Preserve private-credential FD/stdin handling. Publish kit changes
   through `bin/{manifest,seal,vendor}.sh`; do not edit `ops/ci/kit` manually.
   Install the governed auditor via the protected jeryu-tool authority, using
   its approved installer and true installation receipts. Run the exact Linux
   `just required` and independent review before claiming source qualification.

2. **Ordinary image capabilities.** Add a versioned immutable image path in
   `common.sh` rather than overwriting the qualified base. `prepare-image.sh`
   installs public build tools only; root App credentials stay outside. Rustup
   must respect each repo's `rust-toolchain.toml`. Add just, nextest, actionlint,
   advisory/secret scanners only with pinned versions and verified downloads.
   `qualify.sh` must check actual tools, Docker services and egress/credential
   refusals. Extend `launch.sh` admission when increasing CPU/RAM or introducing
   a profile: lock one lane, measure current available RAM/free disk, verify the
   selected image hash and fixed capability labels before registering. Current
   8 vCPU/8 GiB guests remain the baseline, not a certification of large jobs.
   Root receipt fields `runner_id`, `host`, `instance`, `image_sha256`, `time`,
   `completed_at`, `controller_exit`, `workspace_destroyed` remain required.
   Do not equate controller exit 0 with GitHub job success.

3. **Small Linux migrations.** Demo edits are exactly
   `.github/workflows/{proof-html,auto-assign}.yml` and `.github/actionlint.yaml`.
   The assignment defect repair and its real successful final-head run are
   complete; preserve its events and normal assignee intent.
   Application edits are `.github/workflows/ci.yml` and
   `.github/actionlint.yaml` in `work/ai-veox-lan`, a worktree based on the named
   `rc/auto` convoy. Preserve PostgreSQL 16, Python 3.12/Chromium, `just required`,
   `just browser-integration` and the 30-minute quota. Explicit distro rustup
   installation replaces the hosted image assumption. The application additionally requires `browser158`. Use
   `prepare-browser-image.sh`, qualified image/receipt unit environment overrides
   and a real full-browser launch; do not reduce installation to headless-only
   because the repository preflight checks the full browser executable.
   LAN cache keys use `cargo-lan-ubuntu24-x64-v1-`; old hosted caches are not a trusted base. Land
   through `just land`, not a shortcut merge into main or a production deploy.
   Any new diagnosis becomes an attended finding under the repo's own rules.
   Fixture repairs are restricted to
   `crates/veox-app-api/tests/integration/{observability,load}.rs` and
   `docs/ci-utc-fixtures.md`. Preserve exact two-day history and count assertions.
   The existing SQL suite must run with `VEOX_TEST_DATABASE_URL` set. Disposable
   PostgreSQL data uses bounded tmpfs; do not disable fsync or change the quota.
   After the convoy lands, use the owned `work/ai-veox-lan-main` promotion
   branch, cherry-pick the attended fixture and CI-storage commits, retain the
   already-promoted CI files, push PR 251 and bind every gate to its new SHA.

4. **Dope.** Read `AGENTS.md`, `docs/{architecture,testing,release,audit}.md`,
   `agent/{owner-map.json,test-map.json,generated-zones.toml,cost-budget.toml}`.
   Source staging is `work/github-sources/dope`. Linux changes affect
   `.github/workflows/{ci,jankurai}.yml` and `.github/actionlint.yaml`; explicitly
   install rustup in clean guests and namespace CPU caches by the LAN profile.
   Preserve `ops/ci/{cpu,security,audit,tool-adoption,install-jankurai}.sh`, exact
   pinned Jankurai 1.7.1, 85-point full-audit floor and report uploads. Run
   `just fast`, `just check`, `just security`, then real CPU/security/audit jobs
   at the final PR SHA. `.github/workflows/gpu.yml` remains on its existing
   local capability until shared GPU qualification; its weekly 120-minute cap,
   libtorch 2.7/CUDA 12.8, deterministic environment and sealed corpus variables
   must remain. Do not read sealed holdout inputs during a general CI migration.

5. **Jailgun.** Refresh/read its current instruction maps and ops guidance;
   edits are `.github/workflows/{ci,jankurai,security}.yml` and runner-label lint
   configuration. Keep the Ubuntu 24.04 and 26.04 runtime matrix. The separately pinned Ubuntu 26 guest is now qualified; an Ubuntu 24
   guest cannot claim that OS. Preserve Xvfb/X11/user-systemd tests, artifact
   producers/consumers and aggregate dependencies. Required commands include
   `bash ops/ci/scan.sh` and `bash ops/ci/jankurai.sh`, with actual guest tool
   receipts and all matrix children successful.

6. **Bullet.** Read `<family-root>/manifest.toml`, its plan/owner log and current
   `AGENTS.md`; append the family claim before writes. Edit the two existing
   workflows under `.github/workflows/` only in that claimed member. Keep native
   macOS/Windows refusal coverage visible; do not run those jobs in Linux and
   change their names. `bash scripts/ci-local.sh required` and genuine native
   lane outcomes are the completion proof, not workflow syntax alone.

7. **Redline.** Locate the declared canonical checkout on its host; use `bf board`,
   `bf board --to me`, and `bf claim .github/ ops/ci/ -m ...` before edits. Exit 2
   is an overlapping owner claim, not permission to take over. Heartbeat claims
   at least every 30 minutes. No worktrees, sibling source clones, manual audit
   outputs or protection relaxation. Refresh the seven workflows:
   `ci.yml`, `jankurai-tools.yml`, `jankurai.yml`, `packages.yml`,
   `release-build.yml`, `report-merge.yml`, `sqlite-parity-report.yml`.
   Remove every fork/hosted routing expression by using the verified disposable
   Linux group for admitted Linux lanes; keep all approval and secret exclusions.
   `packages.yml` and release matrices retain native macOS Intel/ARM and Linux
   ARM, and Ubuntu 22 compatibility gets its own qualified image/profile.
   Publishing/write-token work needs the trusted-ref release profile, not a PR
   general guest with host credentials. Preserve PostgreSQL 16.15, release
   attestations and official-evidence acceptance. Run `just fast` then
   `REDLINE_TESTING_POSTGRES_URL=<isolated-service-url> just pr-ci`. Required
   `RedlineDB/required`, exact-head independent approval, claim release proof and
   clean canonical source are mandatory. The operator cannot self-review. Independent required review is a source gate,
   not a missing implementation-choice permission from the user.

8. **JopeDime.** Single writer in `/home/ubuntu/JopeDime`; use its AGENT_CHAT flock
   protocol and read the current PR queue before edits. Edit the six workflows
   `ci.yml`, `full-main.yml`, `main-guard.yml`, `release.yml`,
   `runner-admission-probe.yml`, `weekly.yml` plus the declared runner-admission
   action/scripts as a claimed unit. Existing JIT runners already execute on
   xbabe1 and are actively serving unrelated source work; leave them running.
   Replace repo-specific label/provenance expectations with a shared capability
   proof bound to the root receipt/image and an exclusive resource lease.
   Run deliberate wrong-host/image/CPU refusal tests. Preserve all eight manual
   proof lanes, aggregate and main guard, writer/reviewer identity separation,
   stopped-head handoff and independent review. Use `gh-role` helpers, never
   parse/source private PAT files or approve with the writer's identity.

9. **Native/GPU/large profiles.** Native macOS requires suitable physical LAN
   hardware; none of xbabe1/2/3 supplies it. Windows requires a supported
   licensed VM and actual runtime proof. ARM emulation/cross-build is a candidate
   capability requiring acceptance equivalence, not automatic native proof.
   GPU passthrough must not remove a device from an active production workload;
   qualify IOMMU isolation, NVIDIA/driver/CUDA/library inventory and exclusive
   admission before publishing a shared `gpu` label. Increase large CPU lanes
   only after actual capacity/admission and Jope provenance refusal tests.

10. **Drain and final audit.** For each old service, record repository numeric
    ID, actual host, service unit, current busy state and passing replacement
    run/head. Stop new listeners only after that repository's required evidence
    and reviews qualify; wait for active jobs to end, then disable only the
    matched service. Do not delete source checkouts or other owners' build data.
    Disable new repository-level runner creation after the last repo-scoped JIT
    controller is replaced. Expand the shared group to all qualified repositories;
    use one general pool and shared capability profiles, not dedicated repo hosts.

## Failure interpretation and final evidence

`actionlint` success proves syntax only. A queued hosted label proves it was not
executed, not that its check passed. Runner ID 0 has no execution provenance.
Missing browser, CPU/GPU/native capability, auditor stamp, tool digest, required
review or artifact must fail/block the affected lane. Preserve prior evidence
when repair fails; do not downgrade a gate, forge a status or remove a matrix.
Failures in existing product checks stay distinguishable from runner/controller
errors. Re-run only changed or failed checks once routine validation is green.

Evidence schema for each accepted job: repository numeric ID and name, PR URL,
full source SHA, GHA run ID/attempt and URL, job ID/name/conclusion, runner
ID/name/group/labels, physical host, image/tool digests, matching root receipt,
VM stop/workspace destruction and validation timestamp. Collect all matrix
children/called workflows, not just the aggregate. Record controller recovery
after a consumed job and on service restart; verify enabled state on all hosts.
Keep no tokens, private keys, customer data or generated auditor claims in the
handoff. Retain canonical logs/receipts and report their public hashes/paths.

The operator's `outputs/neverhuman-lan-live-job-proof-2026-10-04.json` binds the
nine infrastructure jobs. `neverhuman-pilot-cleanup-proof-2026-10-04.json` proves
pilot destruction. `neverhuman-active-ci-snapshot-2026-10-04.json` captures
active/queued jobs separately. `neverhuman-ci-rollout-receipt-2026-10-04.json`
must be refreshed after each admission/merge, with `objective_complete=false`
until every completion criterion holds. The final handoff includes a fresh
billing/policy/budget readback; billing at 00:08 UTC October 5 showed $0 Actions billed,
$108.84 consumed fully offset, 0/3,000 private minutes and 0.5/2 GB storage.
Repeat storage/billing verification after GitHub's reporting delay following
the last migration. The recurring $12 Team subscription is outside extra
processing charges and has not been changed.

## Atomic deployment and cleanup recovery

Never truncate or overwrite a controller script that a running Bash process is
reading. Stage each changed script under `/opt/neverhuman-actions/`, set root
ownership/mode, run `bash -n`, then atomically rename it over the final path.
`provision.sh` follows the same rule. Existing jobs retain their original inode;
new controllers read the new version. Do not restart a busy controller to apply
a source update. A source refresh does not justify killing unrelated CI.

An earlier in-place operator deployment interrupted cleanup after runners 284
(xbabe1, successful application job) and 286 (xbabe3, successful Dope job)
completed. Their original root receipts/logs remain unchanged. Exact GitHub job
runner IDs, completed job conclusions, stopped per-VM units, consumed registry
IDs and owned non-symlink overlay/seed paths were checked before manual cleanup.
Separate root recovery receipts record `controller_exit=2`,
`automatic_cleanup=false`, and actual workspace destruction. Do not rewrite these
as automatic exit-0 lifecycle successes. Runner 285 on xbabe2 completed its cancelled unrelated Dope audit job and was
reconciled using the same exact-ID, stopped-unit and owned-path checks. Its
controller exit 2 is retained and cancellation is not a pass. All three affected
instances are now reconciled; no affected busy instance remains. Replacement
controllers are completing automatic stop/destruction with exit 0. Root runner 287 on Ubuntu 26 stopped/destroyed its
VM automatically with controller exit 0 after a failed product job, which proves
cleanup only and does not turn that product failure into a pass.

Public recovery evidence is
`outputs/neverhuman-controller-cleanup-recovery-proof-2026-10-04.json`. Keep
automatic lifecycle proofs and manual recovery proofs distinguishable. Validate
new jobs under the atomically installed source and bind replacement runner IDs
to root receipts. Final source kit 1.4.1 hash is
`ca8d8fa2153fac2ebdb1e771b56f19d7e2b704d849ee1bb22b852c4ae8aa0d68`;
Linux seal/vendor/verify and all 20 kit self-tests passed. This is not the
governed product-required qualification or independent authoritative review.


## Remaining exact source and acceptance constraints

These packets are prepared, not implemented or qualified. The operator retains
execution ownership. No user implementation choice is pending. The following
source gates and physical capabilities prevent a truthful complete rollout.

### Redline: canonical xbabe2:/home/ubuntu/redlineDB

Read first in order: AGENTS.md, .jankurai/JANKURAI_STANDARD.md,
agent/{owner-map.json,test-map.json,generated-zones.toml,boundaries.toml},
.jankurai/{owner-map.json,test-map.json,proof-lanes.toml,tool-adoption.toml},
ops/AGENTS.md, docs/{agent-native-standard,testing,ci-trust-boundary}.md,
crates/bench/tests/{ci_workflow_routing,ci_trust_boundary}.rs, then all seven
.github/workflows files. Clean canonical main and origin/main observed at
9277455d5ad008252053a81d18add39b8cdc8f7b. Read the board again before claiming.
No claim, branch change or source write has been made by this migration operator.

From the canonical checkout, with every shell invocation prefixed rtk:

    /home/ubuntu/.local/bin/bf board
    /home/ubuntu/.local/bin/bf board --to me
    pwd; git rev-parse --show-toplevel; git status --short --branch
    /home/ubuntu/.local/bin/bf claim .github/ crates/bench/tests/ci_workflow_routing.rs crates/bench/tests/ci_trust_boundary.rs docs/ci-trust-boundary.md -m 'Shared isolated LAN CI capabilities with native and fork proof preserved'

Only after a successful claim and clean freshly fetched main may the sole
integrator create a branch. Existing docs PR 32 is unrelated: exact-head review
is approved, but 13 hosted jobs remain blocked. Do not merge, amend, cancel or
absorb it to manufacture a migration gate. Four-open-PR limit still applies.

Edit seven workflows, add .github/actionlint.yaml for declared shared labels,
update the two routing/trust tests and trust-boundary document. Register new
paths in both live map copies as their schemas require. Generated audit scores,
official reports, assets and benchmark evidence remain read-only.

Current tests intentionally require hosted light jobs, forbid dtolnay in an old
persistent self-hosted lane and assert fork-hosted fallback. Replace those
assertions with the actual isolation contract rather than removing tests:

- Linux compute jobs name group neverhuman-lan, self-hosted/Linux/X64 and the
  true OS label. Dynamic forks must never select a GitHub-hosted label.
- Forks retain external approval, nonpersistent checkout credentials, temporary
  download caches, no trusted cache publication, parity refusal and aggregate
  failure rules. Update the old fork-routing expression oracle to the verified
  disposable guest route; preserve all token/cache assertions.
- Aggregate needs retain every required child. Keep nextest digest, curl retries,
  artifact warning/failure semantics and official evidence checks.
- packages.yml needs actual Ubuntu 22 x64, Ubuntu 22 ARM, macOS 15 Intel and
  macOS 15 ARM builds AND native installer/runtime proofs. Published installer
  and quickstart consumers remain required. A cross-build is insufficient.
- Release/write-token jobs need a separately admitted trusted-ref shared profile
  with deliberate PR/fork refusal proof. No host key or writer PAT enters guests.

The new acceptance command must fail on parent and pass on head. Use:

    cargo test -p redlinedb-bench --test ci_workflow_routing --test ci_trust_boundary
    actionlint
    git diff --check
    just fast
    REDLINE_TESTING_POSTGRES_URL=<isolated-pinned-PG-service> just pr-ci

The oracle is PostgreSQL 16.15 at the declared digest and settings 160015|C|C|UTC.
Preserve failing names, skips and raw hashes. Missing native profiles leave the
required package gate queued, never successful. PR body must carry bf claim ID
and acceptance command. An eligible reviewer who neither opened nor authored/
committed the PR must approve the exact head; RedlineDB/required must pass at
that same head before merge. Heartbeat claims every 30 minutes and release with
an actual proof command/recorded exit code. Do not self-review or relax protection.

### Bullet: reconcile source authority before writes

Declared family root /home/ubuntu/bullet on xbabe2 is absent. Preserved
/home/ubuntu/bullet.retired-20260921 contains manifest/history;
 /home/ubuntu/bullet-asap-family/bullet-kernel is a dangling symlink to that absent
canonical root. Clean /home/ubuntu/src/bullet-stranger-console/bullet-kernel is a
diagnostic sibling at bd2d7b70e76eaecbfd1e783b36d73a212969fc44, not a claimed
canonical source. GitHub default head observed:
f399d850acf62bc59332d162a7684df23e21e16e. Do not revive, overwrite, relink or
mutate these roots solely to unblock CI. Reconcile current family manifest
GitHub authority with the older SPLIT.md local-forge declaration first.

Read family repos.manifest/owner log, SPLIT.md, AGENTS.md,
agent/JANKURAI_STANDARD.md and maps; claim under the family lock before writes.
Edit .github/workflows/{ci,scheduled}.yml in that claimed member, with a label
lint config if permitted. Preserve all six Linux proof lanes and aggregate,
scripts/ci-local.sh required, and scheduled actual macOS 15/Windows 2025
portable-refusal proof. Native absence is a stop for qualification. Preserve
publication semantics/tool hashes. Deliver an exact-head draft/review packet
after canonical reconciliation, not a mutation of the retired or sibling tree.

### Jope: source queue before another implementation lane

Canonical xbabe2:/home/ubuntu/JopeDime has dirty main behind origin, modified
AGENT_CHAT.md/MASTER_CLEAN_UP and an unrelated untracked .mcp file. At 04:01 UTC
October 5, main was 240 commits behind origin. Nine PRs were open:
188, 186, 185, 180, 178, 177, 148, 147, 137. Seven registered worktrees
already exceed its four-lane ceiling. Read AGENTS.md, MASTER_CLEAN_UP, AGENT_CHAT
and six workflows. No migration claim, branch change or source write exists.
Preserve those owners' work; do not reset/stash/force-push, create another
worktree or merge unrelated product PRs as a queue-clearing shortcut.

When the governed queue permits a new lane, acquire flock/AGENT_CHAT claim,
use permitted .agent work area and gh-role writer/reviewer helpers. Edit
.github/workflows/{ci,full-main,main-guard,release,runner-admission-probe,weekly}.yml
and declared admission action/scripts as one unit. Reanchor repository labels
and host CPU/image expectations to a shared exclusive resource lease bound to
root provenance. Deliberately test wrong host, image, CPU and unowned-lease
refusals. Preserve eight manual proof lanes, aggregate, exact-head independent
reviewer identity and post-merge main guard. Existing repo JIT runs on LAN;
leave active jobs/credentials until shared equivalents pass. Preserve sealed
GPU/corpus inputs; do not inspect holdout data during infrastructure work.

### Drain and final evidence

Legacy assessment found 27 original listeners, most resolving to neverhumanbot
or unavailable repositories. One idle neverhuman/jankurai-audit listener with
no workflows/jobs was stopped/disabled and its registration deleted after
numeric-ID/busy/Worker checks. Twenty-six original services remain; do not
blanket-retire other owners' listeners. Redline's two current dedicated listeners
remain until shared required evidence qualifies. Dope has zero repo runners
observed; its GPU workflow is an unqualified capability.

Use neverhuman-legacy-runner-assessment-2026-10-04.json for exact unit/host/owner
bindings. Before each retirement require current repo ID/ownership, completed
replacement run/head and idle/no-Worker proof. Then stop/disable only that unit
and delete only its exact repo runner ID. Preserve source/recovery files.
Disable repo-runner creation only after Jope's active JIT controller is replaced
and relevant lanes drained.

Refresh seven repositories with work/refresh-ci-snapshot.py; collect successful
jobs with work/collect-product-lan-proofs.py. Preserve original failed attempts
and manual-cleanup distinctions. Saved policy/billing/budget browser readbacks
prove account state at their timestamps. Repeat storage billing after reporting
delay. Keep objective_complete=false until native/GPU/resource/source review,
all real required gates and final drain criteria hold.


## Measured pool expansion

CI-kit 1.4.1 permits lanes 1 through 4 while rejecting lane 5 before VM/JIT
creation. xbabe1/2 remain at two enabled lanes each. xbabe3 lanes 3/4 add two
general Ubuntu 24/browser158 guests. These are shared capability slots, not
repository reservations. Admission required at least 32 GiB MemAvailable and
300 GiB free disk for this two-lane expansion; each normal launch still requires
12 GiB available memory and 100 GiB free disk. Actual admission measurements,
atomic source hashes and unit enable/active states are in
neverhuman-pool-scale-proof-2026-10-04.json. Existing controllers/jobs were not
restarted. Images, App credentials and egress rules are unchanged. All scripts
passed ShellCheck; GNU seal/vendor/verify and all 20 kit tests passed again.
Bind actual new-lane jobs to root stop/destruction receipts before calling the
expansion live-qualified. Both added lanes have now completed actual jobs with
root exit 0, stopped VM and destroyed disk/seed bindings; the expansion is
live-qualified, while remaining product workflow qualification stays separate.


## Dependabot generated jobs and the strict LAN-only boundary

At 03:09 UTC October 5, main Jailgun also exposed generated `Dependabot Updates`
runs 37257753790 and 37257752422. These are separate from the three product gate
workflows. They are not files under .github/workflows/, so a YAML inventory alone
is insufficient. Preserve their IDs/status in the run inventory.

GitHub documents that these jobs bypass Actions policy disablement and that
public repositories cannot select self-hosted Dependabot runners. Standard
Dependabot execution is free; larger runners are billable. Zero configured larger
runners plus the $0 stop-usage budget remains mandatory. Primary documentation:
https://docs.github.com/en/code-security/concepts/supply-chain-security/dependabot-on-actions
https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/manage-your-dependency-security/configure-on-self-hosted-runners

Decision: preserve dependency/security update functionality while identifying it
as an exception to all-processing-on-LAN. Do not disable updates without a
working LAN replacement or claim the hosted-runner switch blocks these generated
jobs. This does not add a paid hosted compute allowance.

Read first: each authoritative repository's AGENTS/maps, .github/dependabot.yml
if present, active bot PR metadata (not private credentials), and organization
Advanced Security Dependabot runner settings through the owner browser. Then
classify public/private repos. Private repos may use a separately qualified
Linux x64/Docker shared Dependabot capability and label/group setting. Public
repos need a LAN dependency updater with equivalent ecosystem, cadence,
lockfile, vulnerability and PR behavior; changing a runner label cannot solve it.

Keep updater credential provisioning separate from the runner-controller App,
which has no repository access. Scope any updater credential to admitted repos
and dependency-PR operations; keep it outside ordinary PR guests. Define a
reviewable implementation/configuration before enabling it. Do not expand the
controller App's privileges or let dependency PRs self-approve or bypass product
gates. Serialize updater writes per repo and honor local claim/PR limits.

Before replacing managed updates: dry-run the actual supported ecosystems in
owned disposable LAN guests, produce dependency/lockfile diffs, open ordinary
draft update PRs only where repository rules allow, and require real product
checks and independent review. Compare generated updates to the existing bot
configuration, verify private credential absence in logs, bind jobs to root
runner receipts, and test failure/queue recovery. Disable the managed updater
only after that replacement proves equivalent behavior. Generated update jobs
remain an explicitly recorded exception until then. No replacement updater or
new updater credential has been created during this rollout.
