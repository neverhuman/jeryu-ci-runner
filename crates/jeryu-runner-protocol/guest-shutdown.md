# Guest shutdown and node loss

Guest-v2 Bind gains required `remaining_lease_millis` (1..86400000). The node
derives it from the signed lease's absolute expiry minus its current verified
clock minus a one-second reset reserve, immediately before writing Bind.
Insufficient remaining time fails boot; the reserve never extends authority.
Guest validation rejects a value above
either the signed lease duration or the signed runtime limit. No public RPC can
select it, rebind a running guest or extend the deadline.

Guestd records a monotonic boot anchor BEFORE exposing its vsock listener. The
accepted connection precedes the node's remaining-time computation. The guest
hard deadline is boot anchor plus remaining_lease_millis, not receipt time or
Ready time. Filesystem setup and Git preparation therefore consume the budget;
the host's absolute signed lease does not restart after a slow boot. This is a
conservative execution bound after Bind and may shorten the run slightly.

An independent trusted PID-1 thread resets the guest at the hard deadline.
It does not need a transport write, an input controller, a guest subprocess,
or the node's watchdog thread. EOF/fatal supervisor error and normal completion
also reset instead of returning PID 1 or leaving an infinite error loop.
The reboot syscall is guarded to guest PID 1; accidental host execution refuses.
All VM descendants and tmpfs authentication material disappear with VM death.

Use RB_AUTOBOOT with the launcher's fixed reboot=k on x86. Firecracker 1.17 has
no x86 ACPI power-off; RB_POWER_OFF halts Linux but leaves the VMM allocated.
The emulated keyboard reset exits Firecracker and does not reboot a live guest.
ARM reset uses PSCI; ARM qualification remains separate. See the pinned
[Firecracker FAQ](https://github.com/firecracker-microvm/firecracker/blob/v1.17.0/FAQ.md).

A separate initial 20-second bootstrap bound starts at guestd boot and limits
an unbound guest. It is NOT proof of signed expiry before Bind for a shorter
lease, a kernel that never reaches guestd, host suspension or VMM pause. The
existing host boot/watchdog/journal fencing remain mandatory, and independent
boot-phase/node-loss qualification remains a production release requirement.
Guest monotonic timing alone is not a universal host wall-clock guarantee.

Automatic idle and runtime shutdown still attempt trusted filesystem freeze
inside the signed lease; the hard timer never waits for freeze or export I/O.
Without the node's validated freeze acknowledgement, retained work must remain
filesystem_flushed=false. VM exit alone never implies a successful agent result.
Startup cleanup uses only journal-owned resources and may retain an unflushed
opaque disk for recovery. No agent-controlled filesystem is mounted on the host.

Acceptance needs an actual KVM guest with the node killed, and another with the
node stopped while its transport stays open. Observe the bound VMM identity and
owned cgroup independently, require observed death at or before signed expiry,
then recover through
the ownership APIs. Healthy-node tests do not prove this behavior. CI uses test
images and model-free agents; real provider credentials are never needed here.
