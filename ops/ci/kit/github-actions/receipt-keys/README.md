# Published lan-ci receipt signing keys

One ed25519 public key per physical pool host, named `<host>.pub` (PEM
SubjectPublicKeyInfo), for example `xbabe2.pub`. These are the trust anchors
for `../verify-receipt.sh --pubkey-dir`; a verifier must pin a copy from here
(or its own reviewed vendored copy), never a key found inside a guest.

Only `README.md` and public `<host>.pub` files belong here. The kit selftest
fails on any other file, on any `*.key` file and on any private-key PEM
material, and the verifier refuses a pinned file that contains a private key.

No key is published yet. To add one, the owner runs `receipt-keygen.sh` as root
on that host, then adds `/etc/neverhuman-actions/receipt-signing.pub` here by PR
together with the printed `key_id` (sha256 of the DER public key). Rotation
replaces the file by PR before the host signs with the new key.
