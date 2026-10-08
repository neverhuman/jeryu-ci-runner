# Managed session node

Managed dispatch boots Firecracker/Jailer 1.17.0 with a verified kernel,
read-only rootfs, private workspace and vsock. It never starts an agent on the
host or substitutes an OCI runner. Ordinary CI policy is separate.

The dedicated launcher runs as a constrained root service. Operators do not
need direct KVM access. `/dev/kvm` must retain restricted group permissions.
Requests select registered profiles and immutable artifact identities, never
host commands, executable paths or environment overrides.

## Admission and identity

The root-owned node config enrolls the control-plane lease verification key
separately from the release key and TLS certificate. Leases are Ed25519 signed
and bind runner identity/epoch, run/session/generation, job digest, runtime,
workspace revisions, resource bounds and provider connection bindings.
Transport uses TLS 1.3 with mutual authentication and an exact control-plane
certificate pin. A different client under the same CA cannot claim work.

Node configuration includes capacity, `cpu_budget_vcpus` (1–2048),
`memory_budget_mib`, `disk_budget_gib` and per-owner limits. Operators specify
budgets after host reserve. RPC cannot override them. CPU charges include
provisioning and cleaning VMs; stopping releases owner quota but fences a
successor writable generation until node cleanup finishes.

Session defaults are 2 vCPU, 4096 MiB RAM, a sparse 16 GiB workspace, 1024 guest
processes, 1 MiB/s output, a two-hour runtime and a 15-minute idle limit.
Development fixtures use smaller explicit resources and do not qualify those
production defaults.

Sparse allocation does not overcommit storage. Admission reserves full logical
workspace capacity, another full image for peak encrypted retention (including
authentication tags and bounded metadata), measured
kernel/rootfs/executable/source copies and existing retained checkpoints.
It compares remaining reservations to actual filesystem free bytes using only
fixed, journal-owned host file metadata. Guest filesystems are never mounted
on the host. Missing historic CPU charges reserve 32 vCPU until reconciliation;
historic image charges reserve 1 GiB.

## Guest and terminal containment

Guestd runs as PID 1; agent and shell processes run as uid 1000. Guest-only
launch helpers refuse accidental calls outside PID 1. A supported kernel must
provide guest cgroup v2 and its pids controller. Root-owned channel groups are
joined before dropping uid; agents cannot migrate out. Channel exit kills the
entire group, including detached `setsid` children, and drains buffered terminal
bytes before reporting exit. VM stop also kills all descendants.

PTY bytes remain raw, including ANSI, NUL, invalid UTF-8 and split UTF-8.
Input queues are bounded. A blocked PTY waits until delivery or channel closure;
an Applied acknowledgement means all bytes reached the PTY. Slow viewers use
independent bounded queues and cursor/gap resynchronization. Viewer revocation
closes their subscriptions. K2 uses a bounded NDJSON Subscribe stream; transport
EOF reconnects, while only an explicit End completes a channel.

## Workspaces, main and recovery

Trusted source bundles bind the source, base and current main revisions. Git
imports and actual rebase execute inside the VM before the agent starts.
Conflict state remains attachable through the shell with `rebase_required`;
agent startup is refused. A ready workspace has a session branch.

Guest root protects `refs/jeryu/*`, its ancestor entries and common directory.
Ordinary uid-1000 edits, staging and commits remain possible. Trusted Git ignores
replacement refs, grafts, shallow overrides, global user config and commit-graph
caches. Preparation limits are signed. Stderr is counted and discarded; only
fixed operation names, exit status and byte counts enter diagnostics.
Object integrity and publication require separate trusted export validation.

Checkpointing freezes writers, captures dirty/index/untracked/ignored work on
a private ref when the index permits it, flushes and retains an authenticated
encrypted disk for seven days. Guest home and temporary directories are fresh
tmpfs and never retained. Resume restores without mkfs, preserves its immutable
predecessor and rebases retained commits onto the next signed main revision.

Node reconciliation runs at startup and every 30 seconds. One corrupt resource
record is quarantined without preventing unrelated cleanup. Unresolved
quarantine blocks admission so unknown UIDs/resources cannot be reused.
Verified pidfd termination still runs after cgroup.kill failure. Storage is
deleted only after proving writers dead. Failed cleanup retains its owned
record and retries; it never accepts an agent-supplied host path.

## Qualification limits

The model-free drivers in `examples/live_fixture.rs` and runnerd's
`examples/live_session.rs` require actual KVM and a separately signed development
registry. Unit tests cannot count as live qualification. No evidence images,
keys or terminal recordings belong in this repository.

This foundation does not prove provider authentication, gateway/relay, bundle
upload, headless VT, per-client control handoff, durable control-plane enrollment,
web/CLI/MCP migration, publication/merge cleanup, production artifact signing or
default-resource canary targets. Legacy launch migration and its inventory gate
remain required. Real-provider modes stay disabled. Protected security,
independent review and exact-head gates remain required before release.
