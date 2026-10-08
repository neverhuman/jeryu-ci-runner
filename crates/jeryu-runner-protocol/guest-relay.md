# Guest relay wire mirror

The normative authority is lane A's hand-written `k3-relay-v1` and
`connection-v1`, reviewed at core commit
`2700ecc32c6214c3307638ad9590233cd2d6c627`. This crate mirrors guest/node
directions in Rust and generates `schemas/jeryu.relay.v1.schema.json`.
It does not replace or relabel the core schemas. Immutable upstream release
composition and independent review remain required before shipping.

Guest frames: `open`, `request-body`, `request-end`, `ack`, `cancel`.
Node frames: `head`, `response-body`, `response-end`, `ack`, `error`.
Both directions use four-byte big-endian JSON lengths, at most 256 KiB.
Bodies are padded standard base64, decoded 1..32768 bytes per chunk.
Only the node derives session/lease/owner/generation identity and gateway
capabilities. These fields and `gateway-open` cannot be guest frames.
Consumer code must select the concrete direction, not the schema envelope.

There are four in-flight requests per VM, a one-MiB acknowledged body window
per direction and a 60-second request idle timeout. Sequence numbers start at
one, are contiguous, and end names the last body sequence (zero if empty).
Body/end/window validation is stateful; shape validation alone is insufficient.
Open replay, head ordering, cancellation, idle timers and renewed lease/
connection authorization must be enforced by the consumers.

The helper-only validator refuses any present authorization with the fixed
`guest_authorization_rejected` code. Null is not absence. Rejected values,
body bytes, headers and request metadata are excluded from Debug and errors.
The future loopback adapter strips only `Bearer jeryu-placeholder` before
framing. Qualified RAM-token mode stays disabled; no option here enables it.
Request headers are at most one each of accept/content-type, nonempty ASCII
1..256 bytes with no controls. Response headers are content-type only.
Paths are single absolute paths with no empty/dot segments, authority, query,
percent encoding, fragment, userinfo, backslash or control bytes.

This amendment enables no guest socket, gateway, provider CLI or credential
delivery. It does not prove helper compatibility with subscriptions, renewal,
account isolation, real TUIs, API-key secrecy, actual vsock transport or KVM.
The audited gateway phase-zero checks remain blocking. Real providers stay
disabled until lane P qualification; CI uses credential-free mocks only.
