# Published lan-ci receipt signing keys

One ed25519 public key per physical pool host, named `<host>.pub` (PEM
SubjectPublicKeyInfo), for example `xbabe2.pub`. These are the trust anchors
for `../verify-receipt.sh --pubkey-dir`; a verifier must pin a copy from here
(or its own reviewed vendored copy), never a key found inside a guest.

Only `README.md` and public `<host>.pub` files belong here, each exactly the
output of `openssl pkey -in <key> -pubout` (no edits, no trailing data). The
kit selftest runs `verify-receipt.sh --check-key` on every `*.pub` and fails
on any other file, on any `*.key` file and on any private-key PEM material.

No key is published yet. To add one, the owner runs `receipt-keygen.sh` as root
on that host, then adds `/etc/neverhuman-actions/receipt-signing.pub` here by PR
together with the printed `key_id` (sha256 of the DER public key). Rotation
replaces the file by PR before the host signs with the new key.
