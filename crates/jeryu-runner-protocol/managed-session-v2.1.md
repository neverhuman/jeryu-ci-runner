# Managed session interfaces v2.1

Owner: lane R (Codex). Reviewer: lane A (Grok). Control-plane consumer: lane C
(Claude). Published for independent review before runtime consumers change.
This document does not establish release qualification or complete migration.

Rust serde types under `src/wire/v2/` are authoritative. The generated mirror is
`../../schemas/jeryu.runner.v2.schema.json`; its filename remains the v2 family
name. The protocol string is **`jeryu.runner.v2.1`**. Unknown fields are rejected.
Existing `jeryu.runner.v1` CI contracts remain unchanged. There is no implicit
acceptance of unsigned v2.0 leases by the managed node.

## K1: signed lease and public connection bindings

`SessionLease.connection_bindings` is required, contains at most three entries,
and is ordered strictly by provider: `claude`, `codex`, `grok`. Each provider
occurs once. A binding contains `provider`, `connection_id`, positive
`connection_generation`, and `mode` (`gateway_helper` or `qualified_ram_token`). Credential kind and billing
stay in the vault. Owners use the `user/` or `service/` prefix. There are no
refresh tokens, API keys, access tokens, gateway capabilities, or billing
fallback fields. Fixture leases may use an empty list. A provider profile
requires its matching binding; a binding alone never enables an unqualified
profile. The broker must also check connection ownership, generation, mode,
revocation, and qualification for every access.

The job digest includes the binding list and all immutable work inputs. Its
domain is `jeryu.runner.managed-job.v2.1`. Assignment identity and lease epochs
are fenced by the signed lease even though they are outside the immutable-job
digest. A checkpoint reference is both digested and signed.

`signature` is a required 128-character lowercase hex encoding of a detached
64-byte Ed25519 signature. Signing bytes are:

1. UTF-8 bytes `jeryu.runner.lease.v2.1` followed by one NUL byte.
2. The complete lease JSON object, excluding **only** its `signature` field.
3. Object keys sorted recursively by lexical string order. Arrays retain order.
4. No whitespace. Strings use serde_json JSON escaping. Numbers are decimal
   integers; floats are rejected. Booleans and null use their JSON literals.

Use `SessionLease::signing_bytes()` to avoid independent encodings. The lease
shape, digest, runtime binding, timestamp bounds, and enrolled-runner binding
must all validate. The node verifies the signature against a trusted enrolled
control-plane public key **before admission/boot**. Request-supplied keys and
runtime signing keys cannot authorize a lease. mTLS peer authorization remains
mandatory separately. Configuration owns key rotation; v2.1 initially uses one
enrolled key and requires a controlled configuration restart for rotation.

Changing an owner, runner epoch, expiry, source, binding generation/mode,
checkpoint, or digest without a new valid signature must fail before boot.
Development fixture lease authority is distinct from runtime authority and is
never embedded in a production binary. Fixture re-signing follows the final
job-digest computation, including resume and concurrent-session mutations.

## K2: Subscribe and bounded live output

Route: mTLS-only `POST /jeryu.runner.v2/subscribe`. JSON body: `SessionSubscribe`
with `message_type: session-subscribe`, request id, actor, session id,
generation, channel id, and `after_sequence`. Cursor zero requests retained
output; a future cursor is rejected. Cursor identity includes session,
generation, and channel. No bearer credentials appear in URLs.

Response: HTTP chunked `application/x-ndjson`. Each newline-terminated JSON
object is a `SessionStreamFrame` (`message_type: session-stream`), at most
256 KiB encoded. Envelope repeats request/session/generation/channel.
`payload.event` is `terminal`, `control`, `snapshot`, `heartbeat`, or `end`.
Terminal bytes remain bytes, including ANSI and split UTF-8. `ControlAck.state`
retains Accepted/Applied/Rejected/Interrupted semantics.

Replay and live registration must share an atomic cursor boundary. Replay
continues in small bounded batches, not a twenty-megabyte per-viewer copy.
An explicit gap uses `TerminalFrame {gap: true, bytes: [], sequence: N}` where
N is the first retained sequence; resubscribe with `after_sequence: N - 1`.
The newest readable cursor and earliest cursor are also in snapshots. If an
overflow occurs during streaming, close after the gap so the client can replay;
never acknowledge lost output as consumed. A transport discontinuity in the
guest channel is a session failure, not a viewer gap.

Recheck grants before replay and each delivery; revocation closes the stream.
The subscriber queue is 16 events, and stream writes have a two-second bound.
Slow clients receive gap/resync or reconnect after a bounded disconnect.
At most 16 global streaming connections leave capacity for control RPCs.
Heartbeat interval is ten seconds. Terminal end drains already accepted output
and emits the final snapshot/end. Losing a viewer never blocks guest execution.
The four-frame replay RPC remains a compatibility read.
Every replay result binds all frames to one session, generation, run and channel.
At most four data frames follow an optional first gap marker; data sequences must
increase. A gap's earliest sequence may equal the first following data sequence.

Shared snapshot/controller DTOs and `SessionRpcResponse` are in this schema.
The closed response adds `message_type: session-rpc-response`, protocol version,
and optional request id (null only for failures before a request can be decoded).
`ok: true` requires exactly one typed result and a request id. Results retain
existing JSON shapes: snapshot, controller lease, control acknowledgement,
terminal-frame list (at most five, including a gap), or `{applied: true}`.
`ok: false` requires only `{error: {code}}`. Unknown fields are rejected.
Error codes contain no rejected input, diagnostic body, or secret value.
Cross-field success/error consistency is also checked by Rust validation.

The current endpoint bounds each connection to 75 seconds; long-lived clients
must reconnect with their last consumed cursor. This is a qualification limit,
not an indefinite-attach guarantee.

## K4: immutable source-bundle upload and retained generation

Route: mTLS-only `POST /jeryu.runner.v2/bundles`. Request body is a four-byte
big-endian metadata length, at most 16 KiB of `BundleUpload` JSON, followed by
exactly `stored_bytes` raw bytes. Total Content-Length must match. Metadata has
`message_type: bundle-upload`, request id, role `source_bundle`, SHA-256 digest,
`bundle_bytes`, and `stored_bytes`. Stored bytes include deterministic zero
padding to a 512-byte block boundary, matching the read-only device digest.
Both are bounded by the one-GiB registry limit. No arbitrary destination, path,
executable role, or public-key field is accepted.

The node streams into a root-owned exclusive staging file, hashes every byte,
verifies length/padding/digest, fsyncs, and publishes atomically without replacing
an existing immutable object. Identical existing bytes are idempotent. Any
collision, truncation, extra bytes, capacity failure, or digest mismatch rejects
the upload. Runtime admission is a separate signed-artifact operation. Upload
does not authorize a lease, resolve protected main, or promote compiled caches.

Checkpoint references include an opaque checkpoint id and manifest digest.
The manifest binds owner/repository/session, prior generation, runtime and
environment, actual frozen Git head, approved main, consistency/flush status,
plaintext/ciphertext digests, sizes, and seven-day expiry. A successor must be
the next generation and match the prior head/base. The retained workspace is an
encrypted opaque disk, never a post-authentication RAM snapshot. Resume restores
that disk into a fresh VM without formatting it. Private Git checkpoint refs
must capture uncommitted work before the next main rebase. Conflict files and
rebase state stay in the workspace; only shell starts in `RebaseRequired`.

Cleanup deletes only journal/manifest-owned identifiers, destroys the retained
key, and remains idempotent. No guest-controlled filesystem is mounted on the
host. Publication and merged-generation deletion require lane C's durable
records/outbox; the checkpoint primitive alone does not prove them.

## K3: guest relay metadata, pending lane A's gateway policy

Guest loopback HTTP adapter forwards to host vsock port **1025**. There is no
NIC. `GuestRelayRequest` is node-built gateway metadata; guest frames never supply
request/session/run/generation/lease authority. The node fills these identities
from the admitted signed lease. The metadata contains
provider, GET/POST method, a relative path, and at most one each of `accept` and
`content-type`. Paths initially prohibit queries, percent encoding, fragments,
userinfo, dot segments, control bytes, backslashes, and external authorities.
Those restrictions need lane A review against actual pinned provider APIs.

The node compares metadata to the admitted signed lease and its connection
binding; the caller cannot select an account, generation, upstream URL, or
management endpoint. Authorization headers supplied to the guest loopback
adapter are discarded. A provider CLI may use a non-secret placeholder token.
The root node sends a per-lease capability to lane C's configured gateway over
mTLS; that capability never enters the guest. The gateway checks lease validity,
connection generation/ownership/revocation/mode and adds credentials upstream.
It applies approved provider/path rules and redirect/IP/DNS policy. Raw request
bodies, headers, and provider content must never enter diagnostic logging.

Lane A published `k3-relay-v1` at core contract commit `b369cdd`. Its
open/body/head/ack/cancel frames own the guest transport; R will add their
Rust mirror before enabling a relay consumer. The accepted `9f1a110` amendment permits four in-flight requests (fifth busy).
Capability expiry is checked at gateway-open. An accepted response may continue
past that time while its execution lease/generation remain valid and its idle
timeout is respected. Each new request needs a fresh capability; a duplicate
open is rejected. Disconnect/replacement still fence an in-flight stream. Refresh/API keys stay central; RAM access-token exceptions
remain disabled unless lane P's independent real-provider qualification passes.
Neither a schema nor a mock provider can establish subscription compatibility.

## Validation and release limits

Run `just contract-drift` and the protocol crate tests for each interface change.
Use test authorities and mock providers in PR CI. Real-provider tests are manual
canary work only. Live KVM must separately demonstrate dispatch, isolation,
terminal controls, checkpoint/resume, conflict retention, and cleanup. The
schemas do not prove authoritative forge resolution, production signing,
connect-once refresh, publication, the product clients, or elimination of every
legacy host/OCI launch. Independent review and genuine protected gates remain
required before release.
