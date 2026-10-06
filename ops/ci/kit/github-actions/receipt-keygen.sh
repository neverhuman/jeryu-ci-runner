#!/usr/bin/env bash
# One-time, owner-run: create this host's ed25519 receipt signing key. Root-only private key
# at /etc/neverhuman-actions/receipt-signing.key (0600); public key beside it (0644 inside the
# 0700 config directory). Publish the public key by PR as
# ops/ci-kit/github-actions/receipt-keys/<host>.pub so verifiers can pin it. Refuses to
# overwrite an existing key; rotation is an explicit owner decision (move the old key aside,
# publish the new key, then enable). Generating a key does not enable signing.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=receipt.sh
source "$(dirname "${BASH_SOURCE[0]}")/receipt.sh"
nh_require_root
pub=${NH_RECEIPT_KEY%.key}.pub
[[ ! -e $NH_RECEIPT_KEY && ! -L $NH_RECEIPT_KEY ]] || { echo "Refusing to overwrite $NH_RECEIPT_KEY" >&2; exit 2; }
install -d -m 0700 -o root -g root "$(dirname "$NH_RECEIPT_KEY")"
umask 077
openssl genpkey -algorithm ed25519 -out "$NH_RECEIPT_KEY.part"
chown root:root "$NH_RECEIPT_KEY.part"
chmod 0600 "$NH_RECEIPT_KEY.part"
mv -- "$NH_RECEIPT_KEY.part" "$NH_RECEIPT_KEY"
nh_receipt_check_key
openssl pkey -in "$NH_RECEIPT_KEY" -pubout -out "$pub"
chmod 0644 "$pub"
echo "Receipt signing key created on $NH_HOST key_id=$(nh_receipt_key_id)"
echo "Publish: copy $pub to ops/ci-kit/github-actions/receipt-keys/$NH_HOST.pub by PR; signing stays off until NH_RECEIPT_SIGNING=required"
