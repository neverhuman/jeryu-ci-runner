# Firecracker runtime image composition

The runtime is Firecracker/Jailer 1.17.0 with a signed exact kernel/rootfs/guestd
identity. This directory owns the fixed image-class overlay and credential-free
test agents. The payload must also contain the pinned real provider CLIs.
Composition does not download them or execute repository recipes.
Dependency installation, package hooks and tool builds must run in build VMs.

The trusted image builder runs the Rust jeryu-compose-runtime-class binary exactly once on its
root-owned unmounted staging tree before packing/signing it. The closed CLI is
`jeryu-compose-runtime-class production|test /absolute/staging/root`. All parent
directories are verified and subsequent operations use no-follow directory
descriptors; existing markers and mock targets are never replaced. Test mock
bytes are embedded from the fixed repository file, installed before the marker,
and synced with fixed 0555/0444 modes regardless of the builder umask. Production refuses
any usr/lib/jeryu/mock object, including dangling links. Test installs the fixed
mock-agent script there. Both add etc/jeryu/runtime-image-class, checked by guestd
before Ready. The signed manifest must declare the matching image_class and
sorted profile_ids. Production runtime admission never trusts the test signer;
test nodes explicitly enroll a different test key and carry no provider binding.

The three mock profiles edit a C file and compile/run it as uid 1000. Their names
identify test cases, not provider emulation. They invoke no model, authentication,
network endpoint, credential helper or real CLI. The production profile registry
does not enable Claude/Codex/Grok yet. Lane P owns pinned CLI adapters and native
authentication qualification outside public PR CI.

Packing uses the trusted producer's fixed filesystem tool on reviewed staging
bytes. Nodes verify exact signed digests and never mount guest-controlled disks.
Complete canonical environment builds, signed release provenance, warm snapshot
qualification and a production default-resource load test remain outstanding.
The development evidence builder is not a production environment readiness proof.

## Node UID enrollment and file custody

The private session-node configuration accepts `uid_base`; omitting it retains
the legacy value `200000`. Each node uses exactly 64 host UIDs. New ranges must
be aligned to 64 and leave room for the entire block without overflow. Reserve
the block against NSS accounts/groups, subordinate allocations, existing node
configurations/resources, and CI identities before installing a node config.
This is a host configuration field, not a runner wire field.

The node persists `uid-range.json` with exclusive creation, root ownership and
mode 0400 under its state lock. A different configured range or malformed
enrollment is refused. A nonlegacy range cannot be assigned to existing state.
Journal reads, writes, cleanup and guardian launch accept only UIDs in that
enrolled block. Legacy records keep their original range and quota rules.

Nonlegacy nodes additionally claim a persistent block in the root-protected
`/var/lib/jeryu-runtime-uid-reservations/nodes/` inventory, using the same
`enrollment.lock` as task reservations. A claim binds the base to the node's
absolute state directory. Another state directory cannot claim that block.
Protected task reservation receipts fence producer IDs and other tasks; a
pre-reserved node block belongs only to node state beneath that task's root.
Claims remain reserved after shutdown. The operator still reconciles legacy
configurations and records before enrollment; this interface does not discover
arbitrary historical node locations or reclaim their ranges.

Composition and configuration reads traverse checked directory descriptors with
no-follow opens. Configuration reads are bounded. Kernel, rootfs and source
bundle admission retains file descriptors; resource charges use their verified
lengths, and boot copies read and hash those same files into exclusive targets.
Changing a checked pathname cannot substitute the copied bytes. Failed copies
leave admission incomplete and existing targets unchanged.

The guardian receives admitted jailer/Firecracker descriptors through private
self-reexec. Self-reexec and jailer exec use held ELF descriptors. The guardian
checks both signed digests, creates a bounded sealed Firecracker snapshot and
rehashes it. Jailer sees the fixed basename inside a private, read-only mount
view, preserving its canonicalization/copy behavior. The snapshot is capped at
64 MiB within the existing 256 MiB supervisor allowance; the durable jailed copy
remains charged as a boot artifact. Guest mount/seal/lifecycle/cleanup validation
is still required. Remaining source/checkpoint promotions retain their separate
custody work.

The producer's [closure inventory and composition gate](closure.md) statically
binds Git, Rust/native tools, public roots/locale and the three exact native CLI
candidates before readiness. Fixed TEST mocks stay unchanged. Including real
CLI bytes never registers or qualifies a provider profile.


Development TEST images carry the actual distro Bash, nohup and /bin/echo,
Git's helpers and templates, and their complete loader dependency closure.
Public CA roots come from reviewed packaged Mozilla certificates; host combined
trust bundles and local fleet certificates are excluded. The producer records
exact source and image digests without running package hooks on the host.

The guest keeps /run at 64 MiB and /tmp at 512 MiB. Development build commands
set TMPDIR=/workspace/tmp after rejecting a symlink and creating that directory
as the unprivileged guest user. Production processes retain TMPDIR=/tmp, and
credential homes remain ephemeral. A changed environment starts a fresh
workspace; retained earlier checkpoints are not resumed across image identities.
