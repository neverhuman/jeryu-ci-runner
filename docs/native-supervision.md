# Native process supervision

`NativeRunner::execute` uses bounded output and an owned launch. Its
`execute_with_options` variant accepts a cancellation handle and private spool
files. The existing `jeryu.runner.v1` schema and receipt status variants are
unchanged. Cancellation and output overflow produce `Failed`; a completed
timeout produces `TimedOut`. Capture, signal, termination, reaping or spool
verification errors cannot produce a successful receipt.

Each stdout/stderr prefix defaults to 8 MiB and has a maximum configurable limit
of 64 MiB. Nonblocking sweeps bound work per stream. A child cannot keep the
watchdog waiting on a reader thread after its group leader exits. Cleanup gets
a separate two-second bound, including pipe drain and child reaping. An error
identifies unresolved cleanup and whether the leader was reaped. The owning
cgroup leaf name is included when available; reconciliation must preserve and
inspect that leaf rather than adopt arbitrary paths or reset state.

Spools must be caller-owned, empty, private, single-link, read/write regular
files opened without append at offset zero. Validate them before spawning;
NativeRunner does so. The watchdog also validates when taking over an existing
child. It sets close-on-exec, writes by explicit offsets, syncs the retained
prefix and rereads its bytes before returning a digest. These are local trusted
supervisor files. This is not immutable server artifact storage or a durable
runner delivery journal. Filesystem I/O availability remains a property of the
selected spool storage; only pipe handling and process polling are nonblocking.

## Termination custody

The supervisor must be the child's sole waiter. It observes exit with
`waitid(WNOWAIT)`, retaining the leader until its last numeric group signal.
It checks signal errors, verifies termination and then reaps. It never sends a
numeric PID/PGID signal after reaping that child. The raw-Child compatibility
entrypoints require a group leader and report `ProcessGroup` scope. They verify
no executing members remain in that group; zombies are already non-executing
and can only be reaped by their own parents. A descendant can leave a process
group, so this scope is not a complete descendant-tree proof.

`spawn_sandboxed_owned` retains a control for its own new cgroup leaf when a
cgroup is admitted. The supervisor-owned parent must not be writable by other
users. Child membership, kill and event files open relative to one held cgroup
v2 directory descriptor, with no-follow and close-on-exec flags. After
`cgroup.kill`, the supervisor requires `cgroup.events` to report no population,
reaps the leader and removes only the empty owned leaf. Detected name/inode
replacement, missing controls or incomplete termination is an error. The
supervisor and administrators must retain exclusive lifecycle custody of its
leaf; same-identity maintenance that races directory replacement is outside
this cooperative filesystem boundary. Job confinement must separately deny
cgroup control and migration access. `OwnedCgroup` describes the verified
cgroup, not an installed service identity or authority qualification.

The raw-Child and PTY launch entrypoints retain their public APIs. Their
callers do not gain the new owned-cgroup lifecycle automatically. In particular,
AgentBridge's PTY reader join, session driver ownership, API WebState lifetime,
service shutdown and cancellation fencing remain separate work. No worker
daemon, server transport, publication, registration or installation is added.

## Cgroup admission

Every selected cgroup parent, including cached or caller-supplied capabilities,
must be an actual cgroup-v2 directory. Probe and launch submit one combined
`+pids +memory` request and require bounded readback containing both bare kernel
controller names before creating a leaf. CPU enablement remains optional and
follows that gate. An ordinary job can still run with no admitted cgroup and an
explicit degraded report; a supplied parent that fails live admission is an
error. The existing strict-plan policy for memory/pids limit writes is unchanged.

Concurrent probes use exclusive PID/time/counter names and retain parent, leaf
and membership descriptors. They never remove a preexisting name. The child
writes zero through the inherited membership descriptor without allocating or
resolving a path after fork. Interrupted writes/waits retry; successful admission
also requires removal of the exact empty probe leaf. Unresolved cleanup emits
its owned leaf identity. This still assumes cooperative exclusive lifecycle
custody against same-identity directory replacement, as above.

Raw-Child launches also bind parent admission, limit writes and child membership
to opened descriptors. Failed launches remove only their exact empty leaf or
report its unresolved identity. This does not give raw callers the owned-cgroup
watchdog or change their process-group termination scope.

## Verification lanes

The normal sandbox/native package tests exercise output limits, both streams,
leader-exit pipe lifetime, cancellation, signal denial, reaping, descriptor
admission, positional spool I/O and spool byte substitution. Existing launch,
AgentBridge and workspace tests remain required consumers. Full Clippy, locked
builds, security, score and contract lanes are still required before acceptance.

The real cgroup lifecycle test is explicitly excluded from ordinary-host tests
because it mutates an allocated delegated parent. It does not count as passing
qualification while excluded. In a separately verified exclusive test parent,
run this exact test with the ordinary shared CI locks and allocation:

```sh
JERYU_TEST_CGROUP_PARENT=/sys/fs/cgroup/approved-worker-test-parent \
CARGO_BUILD_JOBS=2 cargo test --locked -p jeryu-sandbox-linux \
  --test launch_integration \
  owned_cgroup_kills_escaped_groups_and_removes_only_its_leaf \
  -- --ignored --exact --nocapture
```

The test refuses a missing parent, uses real cgroup/no-new-privileges syscalls,
executes a descendant that changes session/group, covers both timeout and
cancellation, and verifies the owned leaf is removed while the parent remains.
It qualifies this cgroup lifecycle only; other sandbox primitives are explicitly
outside that fixture. A missing or unusable delegation is outstanding runtime
qualification, never a successful complete-tree receipt.

The additional probe regression must be selected explicitly in the same kind
of allocated parent, with the test process inside its populated supervisor
subgroup. It proves two concurrent real migrations clean up only their own
leaves, and that probing the populated subgroup fails without changing its
controller state or creating a leaf:

```sh
JERYU_TEST_CGROUP_PARENT=/sys/fs/cgroup/approved-worker-test-parent \
CARGO_BUILD_JOBS=2 cargo test --locked -p jeryu-sandbox-linux --lib \
  capability::tests::delegated_cgroup_probe_checks_topology_and_concurrent_ownership \
  -- --ignored --exact --nocapture
```

Until that selected execution and the existing lifecycle regression pass, their
runtime qualification remains outstanding. This correction alone does not
establish the cause or resolution of Deploy's intermittent `errno95` failure.

Kernel semantics: [cgroup v2 control and population files](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
and [waitid observation without reaping](https://man7.org/linux/man-pages/man2/wait.2.html).
