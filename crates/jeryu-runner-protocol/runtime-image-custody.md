# Runtime image and mock-agent custody

Unreleased runner-v2.1/guest-v2 amendment. Rust types are the authority; both
schemas are generated. image_class and profile_ids are mandatory, with no
legacy defaults. Existing runner-v1 CI contracts are unchanged.

RuntimeManifest.image_class is production or test. profile_ids is a sorted,
unique array of closed profile ids, at most eight, including shell. Production
permits only claude, codex, grok and shell; test permits only fixture,
mock-claude, mock-codex, mock-grok and shell. Declaration is not qualification:
unknown/unqualified entrypoints still fail. Jekko and arbitrary commands are
not registered. Test leases cannot carry connection_bindings at all. Mocks
cannot authorize provider access, including a connection mistakenly assigned
by a trusted control-plane caller. The complete declaration is inside the
runtime digest, job digest and Ed25519 lease signature.

The default registry admission accepts production manifests only, verified
against the root-enrolled release authority. Test admission is a separate
explicit trusted-service path with a distinct enrolled test public key. It
rejects equality between test and production keys and checks image class before
artifact custody/admission. RPC cannot select either key or enable test mode.
Production config omits the test authority. A test-signed image cannot satisfy
production admission or a production qualification lane.

Before Ready, guestd checks its executable digest and an immutable rootfs marker
against the signed manifest. Start also checks the requested profile is declared.
Mock entrypoints reside only in the test rootfs under /usr/lib/jeryu/mock/;
the image composer must reject those files and fixture entrypoints in production
outputs. Mock scripts contain no provider CLI, network destination or credentials.
The guest shell and nested subprocesses retain the same VM boundary.

Acceptance includes a test-signed manifest refused by production admission,
wrong/equal signing authorities refused, production declarations of every mock
rejected, test connection bindings rejected, a signed rootfs marker mismatch
refused before Ready, and all three model-free mock profiles running in actual
Firecracker. Unit tests alone cannot satisfy the live-KVM or provider lanes.

This amendment does not prove real provider adapters/authentication, signed
production build provenance, complete product migration or forge-resolved main.
No real provider may run in PR CI. Lane P coordinates pinned CLI/configuration
and controlled canary qualification separately from these credential-free mocks.
