#!/usr/bin/env bash
# Signed guest receipt: binds a lan-ci guest to the host controller that launched it.
# Sourced by launch.sh and test/receipt-selftest.sh; it does not source common.sh, so the
# offline selftest can exercise it on any machine. Opt-in: NH_RECEIPT_SIGNING=required
# (for example a neverhuman-runner@.service drop-in). The default, off, leaves launch.sh
# byte-for-byte unchanged in what it writes. Once required, a missing, unreadable,
# loosely-permissioned or non-ed25519 key refuses the lane before any VM or JIT exists.
# shellcheck disable=SC2034 # Settings are consumed by the sourcing controller scripts.
NH_RECEIPT_SCHEMA=neverhuman.lan-runner-receipt.v1
NH_RECEIPT_SIGNING=${NH_RECEIPT_SIGNING:-off}
NH_RECEIPT_KEY=${NH_RECEIPT_KEY:-/etc/neverhuman-actions/receipt-signing.key}
NH_RECEIPT_KEY_OWNER=${NH_RECEIPT_KEY_OWNER:-0}
NH_RECEIPT_GUEST_DIR=/etc/neverhuman-ci

nh_receipt_enabled() {
  case $NH_RECEIPT_SIGNING in
    off) return 1 ;;
    required) return 0 ;;
    *) echo 'Unapproved NH_RECEIPT_SIGNING value (off|required)' >&2; exit 2 ;;
  esac
}

# Root-only, regular, ed25519. Checked before the job directory, VM or JIT config exists.
nh_receipt_check_key() {
  [[ -f $NH_RECEIPT_KEY && ! -L $NH_RECEIPT_KEY ]] || { echo "Receipt signing key absent: $NH_RECEIPT_KEY" >&2; exit 2; }
  local owner_mode
  owner_mode=$(stat -c '%u %a' -- "$NH_RECEIPT_KEY")
  case $owner_mode in
    "$NH_RECEIPT_KEY_OWNER 600" | "$NH_RECEIPT_KEY_OWNER 400") ;;
    *) echo "Receipt signing key must be owner $NH_RECEIPT_KEY_OWNER mode 0600/0400 (found $owner_mode)" >&2; exit 2 ;;
  esac
  [[ $(openssl pkey -in "$NH_RECEIPT_KEY" -noout -text 2>/dev/null | head -n1) == 'ED25519 Private-Key:' ]] ||
    { echo 'Receipt signing key is not a readable ed25519 private key' >&2; exit 2; }
}

# key_id = sha256 of the DER SubjectPublicKeyInfo; the verifier recomputes it from its pinned key.
nh_receipt_key_id() { openssl pkey -in "$NH_RECEIPT_KEY" -pubout -outform DER | sha256sum | cut -d' ' -f1; }

# Writes $NH_JOB/guest-receipt.json (+ .sig, + .pub) and self-verifies the signature.
# Needs NH_INSTANCE NH_HOST NH_OS_LABEL NH_UBUNTU_VERSION NH_IMAGE_RECEIPT
# NH_QUALIFICATION_RECEIPT NH_JOB. The runner name registered by launch.sh is NH_INSTANCE,
# which is what GitHub exposes to the guest job as $RUNNER_NAME.
nh_receipt_issue() { # <lane> <image_sha256>
  local lane=${1:?lane} image_sha256=${2:?image sha256} now json sig pub
  nh_receipt_check_key
  json=$NH_JOB/guest-receipt.json sig=$NH_JOB/guest-receipt.json.sig pub=$NH_JOB/guest-receipt.pub
  now=$(date -u +%s)
  jq -cn --arg schema "$NH_RECEIPT_SCHEMA" --arg host "$NH_HOST" --argjson lane "$lane" \
    --arg instance "$NH_INSTANCE" --arg os_label "$NH_OS_LABEL" --arg ubuntu_version "$NH_UBUNTU_VERSION" \
    --arg image_sha256 "$image_sha256" \
    --arg image_receipt_sha256 "$(sha256sum "$NH_IMAGE_RECEIPT" | cut -d' ' -f1)" \
    --arg qualification_receipt_sha256 "$(sha256sum "$NH_QUALIFICATION_RECEIPT" | cut -d' ' -f1)" \
    --arg qualification_log_sha256 "$(jq -r '.log_sha256 // ""' "$NH_QUALIFICATION_RECEIPT")" \
    --arg qualification_ref "$NH_QUALIFICATION_RECEIPT" \
    --arg issued_at "$(date -u -d "@$now" +%FT%TZ)" --argjson issued_at_epoch "$now" \
    --arg nonce "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" --arg key_id "$(nh_receipt_key_id)" \
    '{schema:$schema,host:$host,lane:$lane,instance:$instance,runner_name:$instance,os_label:$os_label,
      ubuntu_version:$ubuntu_version,image_sha256:$image_sha256,image_receipt_sha256:$image_receipt_sha256,
      qualification_receipt_sha256:$qualification_receipt_sha256,qualification_log_sha256:$qualification_log_sha256,
      qualification_ref:$qualification_ref,issued_at:$issued_at,issued_at_epoch:$issued_at_epoch,
      nonce:$nonce,key_id:$key_id}' > "$json"
  openssl pkeyutl -sign -rawin -inkey "$NH_RECEIPT_KEY" -in "$json" -out "$sig" ||
    { echo 'Receipt signing failed' >&2; exit 2; }
  openssl pkey -in "$NH_RECEIPT_KEY" -pubout -out "$pub"
  openssl pkeyutl -verify -pubin -inkey "$pub" -rawin -in "$json" -sigfile "$sig" >/dev/null 2>&1 ||
    { echo 'Receipt self-verification failed' >&2; exit 2; }
}

# write_files entries appended to the cloud-config write_files list. base64 keeps the
# signed bytes exact and leaves no YAML quoting surface. The public key is NOT shipped in
# the seed: verifiers pin the published key (receipt-keys/<host>.pub), never a guest copy.
nh_receipt_cloud_files() {
  local name file
  for name in receipt.json receipt.json.sig; do
    file=$NH_JOB/guest-$name
    printf "  - path: %s/%s\n    permissions: '0644'\n    encoding: b64\n    content: %s\n" \
      "$NH_RECEIPT_GUEST_DIR" "$name" "$(base64 -w0 "$file")"
  done
}
