# Client control and headless terminal amendment

Status: unreleased K2 amendment to jeryu.runner.v2.1; guest wire deliberately
advances to jeryu.guest.v2. A v1 guest cannot satisfy this runtime manifest.
Rust serde/validation is authoritative. Both schemas are generated, with drift
tests. Existing jeryu.runner.v1 CI remains unchanged.

## One writer attachment

AcquireControl requires actor, controller_id, terminal_channels, session_id,
generation and takeover. The trusted control plane assigns a distinct opaque
controller_id to each attachment. An actor is a principal; controller_id is a
client identity, never a bearer credential. Do not reuse a user's id across
attachments or accept caller-chosen reuse. Only the enrolled mTLS control plane
can assert these fields. The node binds both identities to the controller epoch.
Only the owner can request explicit takeover. A second client of the SAME actor
is busy without takeover. Renewing the same actor/client retains its epoch.

terminal_channels is an explicitly supplied, sorted, unique subset of
[agent, shell], with at most two entries. An attached real terminal claims its
channel. Structured API/MCP controllers supply an empty list. Viewer terminals
do not acquire input authority. Expired/revoked clients cannot suppress headless
responses. ControllerLease returns the signed context, actor, controller_id,
terminal_channels, epoch, next_sequence and an expiry upper bound of 30 seconds.
Clients renew every 10 seconds. validate_for binds all reply identities.

## Acknowledged guest fence

Guest ControlFence carries request_id, positive epoch, ttl_millis (0..30000),
and terminal_channels. TTL zero revokes, requiring an empty channel list.
Guest ControlFenced acknowledges the matching request id and epoch only after
the authority change. The guest never learns provider credentials from a fence.
Input, Resize and Interrupt require control_epoch. Each nonblocking PTY write
checks epoch and the monotonic guest deadline under the same mutex used to
change authority. Handoff therefore cancels queued/in-flight old-epoch writes
before the fence acknowledgement. Bytes already delivered to the PTY cannot be
withdrawn. Partial cancellation is REJECTED with a fixed reason, never Applied.

The node blocks controls while a handoff or renewal is pending and prioritizes
fences over ordinary queued commands. AcquireControl and control-grant revocation
do not report success until the guest fence is acknowledged. Failure or a bounded
three-second timeout terminates the VM; it never grants unfenced authority.
The node starts its own 30-second deadline after acknowledgement. The guest
deadline starts on fence receipt, so it may expire earlier than the node. A guest
rejection at that conservative boundary is visible. Stale/unknown fence replies
fail the session. Grant checks and epoch checks also run before queue dispatch.

## Headless screen

Without a real controller terminal, guestd answers bounded CPR, DA and DSR queries
using its per-channel VT screen. When a real terminal holds the lease, raw query
bytes pass through and guestd supplies no competing reply. Raw bytes and terminal
replay stay unchanged. OSC clipboard/hyperlink actions have no host callbacks.
The in-memory screen has no scrollback, at most 200 rows / 400 columns, and a
64 KiB plain UTF-8 text snapshot with an explicit truncation flag. Cursor offsets
are zero based. Screen sequence means the last included raw output frame; zero
is allowed before output. Screen RPC requires viewer authorization and binds
context/channel just like replay. Guest screens cannot advance past raw output.

This amendment does not qualify a provider CLI, subscription mode, product
client, production rootfs, release artifact or the complete launch migration.
Until independent review and actual KVM tests pass, it is development only.
