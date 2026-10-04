# Shared LAN GitHub Actions rollout

Owner: the operator executing the neverhuman CI migration. Updated 2026-10-04.

## Objective and current qualification

Keep extra GitHub processing charges at $0 and run CI on xbabe1, xbabe2 and
xbabe3 through shared organization runners. Preserve required checks, source
authority, release evidence and platform coverage. Never treat a missing runner,
cancelled run, skipped lane or local-only success as a green required check.

The owner browser currently confirms standard hosted runners disabled, zero
configured larger runners, $0 Actions billed, and $0 stop-usage budgets for
Actions, Packages, Codespaces and Git LFS. The Team subscription is separate.
External fork workflows require approval from all outside collaborators. Shared
group `neverhuman-lan` is ID 3. Admission is staged by repository; this is one
shared pool, with no repository-owned VM/controller. Each VM passed the runner/Docker, GitHub and
forge HTTPS, LAN/metadata/public SSH denial and credential-absence checks in
`qualify.sh`. These are infrastructure proofs, not repository CI passes.

Owner authentication is complete. Private org App
`neverhuman-lan-runner-controller` (App 5190166, installation 167953338) has only
organization Self-hosted runners read/write, no repository access and no webhook.
One boot-enabled `neverhuman-runner@1.service` per host automatically creates and
destroys single-job VMs. Lane 2 remains disabled. App credentials are root-only;
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
37241411624 passed; Full Jankurai 37241411579 is pending final completion.
Dope's GPU workflow still uses its existing local dedicated capability.
The credential-free local `just check` VM also passed and was destroyed.

Application draft https://github.com/neverhuman/ai-veox-app/pull/250 starts from
`rc/auto`, head `f9415f6bdd992e243840f99149e26c20b2478f6f`. Required run
37241735053 is running on qualified browser158 runner 278 on xbabe2.
Earlier run 37238732343 timed out downloading Chromium; it is cancelled,
not a product pass. Group admission now contains demo-repository, ai-veox-app
and dope (numeric IDs 1388268629, 1336448620 and 1394151792), all workflows,
with public-repository access enabled under the verified VM boundary.

CI-kit 1.3.0 adds an immutable Playwright 1.58 browser profile. All three
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
do not enable duplicate CI to inflate migration counts. Demo and Dope Linux migrations have landed; full platform
migration remains incomplete. Old hosted-label jobs are queued behind the disabled
policy. Existing local product runners remain until their replacements qualify.

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
   Add lane 2 only after measured memory/disk/CPU admission. A successful runner
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
   qualify,launch,api,egress,provision}.sh`, units and this runbook as needed. `api.sh`
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
   configuration. Keep the Ubuntu 24.04 and 26.04 runtime matrix. Qualify a
   separately pinned Ubuntu 26 guest before admitting that label; an Ubuntu 24
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
   clean canonical source are mandatory. The operator cannot self-review.

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
billing/policy/budget readback; billing at 22:13 UTC showed $0 Actions billed,
$108.82 consumed fully offset, 0/3,000 private minutes and 0.5/2 GB storage.
Repeat storage/billing verification after GitHub's reporting delay following
the last migration. The recurring $12 Team subscription is outside extra
processing charges and has not been changed.
