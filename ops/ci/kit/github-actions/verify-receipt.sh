#!/usr/bin/env bash
# Guest-side verifier for the signed lan-ci receipt written by launch.sh (receipt.sh).
# Standalone: needs bash, jq, openssl and sha256sum; never sources the host controller.
#   verify-receipt.sh (--pubkey FILE | --pubkey-dir DIR) [--receipt FILE] [--sig FILE]
#                     [--runner-name NAME] [--max-age SECONDS] [--boot-window SECONDS]
#                     [--now EPOCH] [--boot-time EPOCH]
# The trust anchor is a published, pinned ed25519 PUBLIC key (--pubkey-dir selects
# <host>.pub from the receipt's host, which the signature then binds); a pinned file holding
# private-key material is refused on every OpenSSL version. The receipt, signature and key
# are each read once into a private 0600 copy and only the copies are interpreted. Checks:
# ed25519 signature, schema, key_id, runner_name == instance == $RUNNER_NAME, issued no
# later than now+60s and no older than --max-age (default 86400), and that this guest booted
# within --boot-window seconds after issue (default 900; 0 disables). Prints the verified
# receipt JSON on success. Exit 0 verified, 1 refused, 2 usage.
set -euo pipefail
receipt=/etc/neverhuman-ci/receipt.json sig='' pubkey='' pubkey_dir=''
runner_name=${RUNNER_NAME:-} max_age=86400 boot_window=900 now='' boot_time='' skew=60
usage() { sed -n '3,6p' "$0" >&2; exit 2; }
refuse() { echo "receipt refused: $*" >&2; exit 1; }
# Canonical non-negative integers only: no sign, no leading zero, at most 12 digits.
is_uint() { [[ $1 =~ ^(0|[1-9][0-9]{0,11})$ ]]; }
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case $1 in
    --receipt) receipt=$2 ;;
    --sig) sig=$2 ;;
    --pubkey) pubkey=$2 ;;
    --pubkey-dir) pubkey_dir=$2 ;;
    --runner-name) runner_name=$2 ;;
    --max-age) max_age=$2 ;;
    --boot-window) boot_window=$2 ;;
    --now) now=$2 ;;
    --boot-time) boot_time=$2 ;;
    *) usage ;;
  esac
  shift 2
done
sig=${sig:-$receipt.sig}
[[ -n $pubkey || -n $pubkey_dir ]] || usage
for value in "$max_age" "$boot_window" "${now:-0}" "${boot_time:-0}"; do is_uint "$value" || usage; done
for tool in jq openssl sha256sum mktemp; do command -v "$tool" >/dev/null || refuse "missing tool $tool"; done
[[ -n $runner_name ]] || refuse 'RUNNER_NAME is empty'

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
chmod 0700 "$work"
umask 077
# One bounded read of each input into the private directory; nothing re-reads the originals.
snapshot() { # <source> <dest> <max bytes>
  [[ -f $1 ]] || refuse "absent: $1"
  head -c "$(( $3 + 1 ))" -- "$1" > "$2" || refuse "unreadable: $1"
  (( $(stat -c %s -- "$2") <= $3 )) || refuse "larger than $3 bytes: $1"
}
snapshot "$receipt" "$work/receipt.json" 65536
snapshot "$sig" "$work/receipt.sig" 64
(( $(stat -c %s -- "$work/receipt.sig") == 64 )) || refuse 'signature is not 64 bytes (ed25519)'
if [[ -z $pubkey ]]; then
  host=$(jq -er '.host | strings' "$work/receipt.json" 2>/dev/null) || refuse 'receipt host unreadable'
  [[ $host =~ ^[a-z0-9-]+$ ]] || refuse 'receipt host is not a plain host name'
  pubkey=$pubkey_dir/$host.pub
fi
[[ ! -L $pubkey ]] || refuse "pinned key is a symlink: $pubkey"
snapshot "$pubkey" "$work/pinned.pub" 4096
# OpenSSL 3.5 accepts a private key where -pubin asks for a public one; 3.0 refuses. Refuse
# private material outright, and require exactly one PEM public key block, ed25519.
if grep -q 'PRIVATE KEY' "$work/pinned.pub"; then refuse "pinned key file holds private key material: $pubkey"; fi
[[ $(grep -c -- '-----BEGIN ' "$work/pinned.pub") == 1 && $(head -n1 "$work/pinned.pub") == '-----BEGIN PUBLIC KEY-----' ]] ||
  refuse "pinned key is not a single PEM public key: $pubkey"
public_text=$(openssl pkey -pubin -in "$work/pinned.pub" -noout -text_pub 2>/dev/null) || public_text=''
[[ $public_text == 'ED25519 Public-Key:'* ]] || refuse "pinned key is not ed25519: $pubkey"

openssl pkeyutl -verify -pubin -inkey "$work/pinned.pub" -rawin -in "$work/receipt.json" -sigfile "$work/receipt.sig" >/dev/null 2>&1 ||
  refuse 'signature does not verify against the pinned key'
# Only the signed private copy is interpreted from here on.
field() { jq -er --arg k "$1" '.[$k] | select(type == "string" or type == "number")' "$work/receipt.json" 2>/dev/null || refuse "field $1 missing"; }
[[ $(field schema) == neverhuman.lan-runner-receipt.v1 ]] || refuse 'unknown schema'
key_id=$(openssl pkey -pubin -in "$work/pinned.pub" -outform DER | sha256sum | cut -d' ' -f1)
[[ $(field key_id) == "$key_id" ]] || refuse 'key_id does not match the pinned key'
[[ $(field runner_name) == "$runner_name" ]] || refuse "runner_name is not $runner_name"
[[ $(field instance) == "$runner_name" ]] || refuse 'instance does not equal runner_name'
issued=$(field issued_at_epoch)
is_uint "$issued" || refuse 'issued_at_epoch is not a canonical integer'
now=${now:-$(date -u +%s)}
(( issued <= now + skew )) || refuse 'issued in the future'
(( now - issued <= max_age )) || refuse "older than $max_age seconds"
if (( boot_window > 0 )); then
  boot_time=${boot_time:-$(awk '/^btime / {print $2}' /proc/stat)}
  is_uint "$boot_time" || refuse 'guest boot time unreadable'
  (( boot_time + skew >= issued )) || refuse 'guest booted before the receipt was issued'
  (( boot_time - issued <= boot_window )) || refuse "guest booted more than $boot_window seconds after issue"
fi
jq -c . "$work/receipt.json"
