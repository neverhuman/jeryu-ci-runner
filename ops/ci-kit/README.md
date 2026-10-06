# jeryu ci-kit

Shared CI helpers for the jeryu split family, owned here and vendored into each
repository as a pinned copy (the same model as the Jankurai pin).

- `lib/jankurai.sh`: `require_tool`, `require_jankurai`, `jankurai`. The caller
  exports its generated `JERYU_JANKURAI_*` pin block first.
- `lib/security.sh`: `ci_kit_secret_scan [skip-glob...]`, `ci_kit_forbid_env_files`.
- `lib/jobs.sh`: `ci_kit_resolve_jobs` (governor-driven `JERYU_CI_JOBS`).
- `github-actions/`: owner-operated Ubuntu/KVM preparation, live network
  qualification and shared ephemeral GitHub runner controllers. This is a
  deployment candidate; see `docs/runbooks/github-actions-lan.md` in the source
  repository for its qualification and activation requirements.

Repository-specific lanes (fleet score floor, extra security tools, the lanes
a `pr-ci.sh` runs) stay in each repository's `ops/ci/`.

### Signed guest receipts (opt-in)

`github-actions/launch.sh` can hand each lan-ci guest an ed25519-signed receipt
through its cloud-init seed, so a job can prove it runs in a VM that this pool
controller launched from a qualified image. Off by default; nothing changes
until a host sets `NH_RECEIPT_SIGNING=required` (for example a
`neverhuman-runner@.service.d/` drop-in with `Environment=NH_RECEIPT_SIGNING=required`).

- Key: `receipt-keygen.sh` (root, once per host) creates
  `/etc/neverhuman-actions/receipt-signing.key` (root, 0600) and the public key
  beside it. Publish the public key as `github-actions/receipt-keys/<host>.pub`.
- Receipt: `/etc/neverhuman-ci/receipt.json` plus the raw signature
  `/etc/neverhuman-ci/receipt.json.sig` in the guest (schema
  `neverhuman.lan-runner-receipt.v1`): `host`, `lane`, `instance` and
  `runner_name` (both equal the JIT runner name, i.e. the job's `$RUNNER_NAME`),
  `os_label`, `ubuntu_version`, `image_sha256`, `image_receipt_sha256`,
  `qualification_receipt_sha256`, `qualification_log_sha256`,
  `qualification_ref`, `issued_at`, `issued_at_epoch`, `nonce`, `key_id`. The
  host keeps the same bytes as `jobs/<instance>/guest-receipt.json{,.sig}` and
  records `guest_receipt_sha256` in its runner receipt.
- Fail closed: with `required`, a missing, symlinked, non-root, loosely
  permissioned or non-ed25519 key refuses the lane before any VM or JIT config
  exists. The key path and owner are fixed; the environment cannot redirect
  them. Only the offline selftest may, via `NH_RECEIPT_ALLOW_TEST_KEY=1`
  (the `JERYU_JANKURAI_ALLOW_TEST_RECEIPT` pattern), and `launch.sh` and
  `receipt-keygen.sh` reject that flag. The key-type check reads only the
  public half (`openssl pkey -noout -text_pub`).
- Verify (inside the job):

      bash verify-receipt.sh --pubkey-dir <pinned copy of receipt-keys/>

  It reads the receipt, signature and pinned key once each into a private
  0600 temp copy (removed by a trap) and interprets only the copies. It
  refuses a pinned file that holds any `PRIVATE KEY` material or is not
  exactly one ed25519 PEM public key (OpenSSL 3.5 would otherwise accept a
  private key under `-pubin`), a signature that is not 64 bytes and a receipt
  over 64 KiB. It then checks the signature against the pinned key, the schema
  and `key_id`, `runner_name == instance == $RUNNER_NAME`, freshness
  (`--max-age`, default 86400 s; at most 60 s in the future) and that the guest
  booted within `--boot-window` (default 900 s) after issue. Numeric options
  must be canonical integers (no sign, no leading zero, at most 12 digits). It
  prints the verified receipt.
  Equivalent recipe without the script: `openssl pkeyutl -verify -pubin -inkey
  <host>.pub -rawin -in receipt.json -sigfile receipt.json.sig`, then compare
  the fields above with `jq`.
- `receipt-keys/` may hold only `README.md` and public `<host>.pub` files; the
  selftest fails on any `*.key` file or `PRIVATE KEY` material there.
- `test/receipt-selftest.sh` (run by `test/selftest.sh`) covers signing,
  fail-closed key checks, the test-only override, seed encoding, pinned-key
  hygiene and every verifier refusal offline.

## Versioning

`VERSION` is the kit version; the content hash is the sha256 of
`MANIFEST.sha256`. After changing any kit file, bump `VERSION` and run
`bash ops/ci-kit/bin/seal.sh`. `ops/ci/check.sh` fails if the kit is unsealed.

## Vendoring

    bash ops/ci-kit/bin/vendor.sh <target-repo-root>

writes `<target>/ops/ci/kit/` and `<target>/ops/ci/kit.pin`. The consumer's
gate runs `bash ops/ci/kit/bin/verify.sh .`, which fails when the copy differs
from its pin. Pass `--canonical <path-to-jeryu-ci-runner>/ops/ci-kit` to also
fail when the pin is behind the canonical kit. Never edit a vendored copy; fix
the kit here and re-vendor.

`bash ops/ci-kit/test/selftest.sh` is the offline regression suite.
