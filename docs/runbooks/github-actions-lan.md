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
External fork workflows require approval. Shared group `neverhuman-lan` is ID 3,
with no repository access yet. One owner-browser-registered ephemeral pilot VM
per physical host is listening. Each VM has passed the runner/Docker, GitHub and
forge HTTPS, LAN/metadata/public SSH denial and credential-absence checks in
`qualify.sh`. These are infrastructure proofs, not repository CI passes.

Automatic replacement is not activated. GitHub stopped app creation at the
owner's Confirm access challenge. General and platform workflow migration has
not landed. Hosted-label workflows can now fail or block because the owner
requested immediate hosted execution shutdown.

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
  Browser access expansion requires action-time owner confirmation.
- The current Linux-only fleet cannot satisfy native macOS jobs. Resolve with
  the owner before claiming full platform migration. Linux ARM jobs need an
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
   Rust/just/nextest/security tools and the governed auditor are not yet baked
   into this initial VM image. Install through their authorities and qualify
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
2. Finish the owner's GitHub access verification. Prepare a private org-owned
   registration app with Self-hosted runners read/write only, no webhook,
   repository content/write, billing, deployment or review permissions. Confirm
   the exact access expansion before creating/installing it. Put IDs in
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
7. Before enabling public access, review the live isolation receipts and obtain
   the required owner confirmation for group access expansion. Grant shared
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
   all 38 active repositories, all 46 initial workflows and matrices/reusables;
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
