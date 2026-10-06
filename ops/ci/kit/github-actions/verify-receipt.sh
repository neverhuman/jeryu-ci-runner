#!/usr/bin/env bash
# Guest-side verifier for the signed lan-ci receipt written by launch.sh (receipt.sh).
# Standalone: needs bash, jq, openssl and coreutils; never sources the host controller.
#   verify-receipt.sh (--pubkey FILE | --pubkey-dir DIR) [--receipt FILE] [--sig FILE]
#                     [--runner-name NAME] [--max-age SECONDS] [--boot-window SECONDS]
#                     [--now EPOCH] [--boot-time EPOCH]
#   verify-receipt.sh --check-key FILE      (validate one pinned/published key and exit)
# The trust anchor is a published, pinned ed25519 PUBLIC key (--pubkey-dir selects
# <host>.pub from the receipt's host, which the signature then binds). A pinned file must be
# byte-for-byte OpenSSL's own canonical re-encoding of one ed25519 public key
# (`openssl pkey -pubin -in F -pubout`), and anything `openssl pkey -in F` (no -pubin) loads
# as a private key is refused; relabelled, appended or header-less private material fails on
# every OpenSSL version. The receipt, signature and key are each opened once, without
# following a symlink, and read into a private 0600 copy; only the copies are interpreted. Checks: ed25519 signature, schema, key_id,
# runner_name == instance == $RUNNER_NAME, issued no later than now+60s and no older than
# --max-age (default 86400, at most 604800), and that this guest booted within --boot-window
# seconds after issue (default 900; 0 disables). Prints the verified receipt JSON on
# success. Exit 0 verified, 1 refused, 2 usage.
set -euo pipefail
receipt=/etc/neverhuman-ci/receipt.json sig='' pubkey='' pubkey_dir='' check_key=''
runner_name=${RUNNER_NAME:-} max_age=86400 boot_window=900 now='' boot_time='' skew=60
max_age_limit=604800 # 7 days: a larger window is not freshness any more
usage() { sed -n '3,7p' "$0" >&2; exit 2; }
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
    --check-key) check_key=$2 ;;
    --runner-name) runner_name=$2 ;;
    --max-age) max_age=$2 ;;
    --boot-window) boot_window=$2 ;;
    --now) now=$2 ;;
    --boot-time) boot_time=$2 ;;
    *) usage ;;
  esac
  shift 2
done
for value in "$max_age" "$boot_window" "${now:-0}" "${boot_time:-0}"; do is_uint "$value" || usage; done
(( max_age <= max_age_limit )) || usage
for tool in jq openssl sha256sum mktemp cmp stat head timeout; do command -v "$tool" >/dev/null || refuse "missing tool $tool"; done

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
chmod 0700 "$work"
umask 077
# One bounded read of each input into the private directory; nothing re-reads the originals.
# The input is opened once and read only through that descriptor. The opened file (fstat via
# /proc/self/fd) must be the same regular file (dev:inode:type) that the path names when
# lstat'ed after the open, so a symlink, or a file swapped in after a check, is never read.
# The child runs under timeout so a FIFO raced in after the type check cannot hang us.
# shellcheck disable=SC2016 # Expanded by the child bash, not here.
snapshot_child='set -u
exec {fd}<"$1" || exit 1
opened=$(stat -L -c "%d:%i:%F" -- "/proc/self/fd/${fd}") || exit 3
named=$(stat -c "%d:%i:%F" -- "$1") || exit 3
[[ $opened == "$named" && ${named#*:*:} == regular* ]] || exit 3
head -c "$(( $3 + 1 ))" <&"$fd" > "$2" || exit 1'
snapshot() { # <source> <dest> <max bytes>
  local src=$1 dest=$2 max=$3 kind rc=0
  kind=$(stat -c %F -- "$src" 2>/dev/null) || refuse "absent: $src"
  [[ $kind != 'symbolic link' ]] || refuse "is a symlink: $src"
  [[ $kind == regular* ]] || refuse "not a regular file: $src"
  timeout 10 bash -c "$snapshot_child" snapshot "$src" "$dest" "$max" || rc=$?
  case $rc in
    0) ;;
    3) refuse "changed while being opened (symlink or replaced file): $src" ;;
    124) refuse "timed out reading: $src" ;;
    *) refuse "unreadable: $src" ;;
  esac
  (( $(stat -c %s -- "$dest") <= max )) || refuse "larger than $max bytes: $src"
}
# A pinned key file must be exactly OpenSSL's canonical PEM of one ed25519 public key.
pin_key() { # <path>: snapshot to $work/pinned.pub and validate, or refuse
  local path=$1 public_text
  snapshot "$path" "$work/pinned.pub" 4096
  if grep -q 'PRIVATE KEY' "$work/pinned.pub"; then refuse "pinned key file holds private key material: $path"; fi
  # Without -pubin OpenSSL loads only private keys (3.0 and 3.5 alike); empty passphrase and
  # no stdin, so an encrypted key cannot prompt.
  if openssl pkey -in "$work/pinned.pub" -noout -passin pass: </dev/null >/dev/null 2>&1; then
    refuse "pinned key file loads as a private key: $path"
  fi
  openssl pkey -pubin -in "$work/pinned.pub" -pubout -out "$work/canonical.pub" </dev/null >/dev/null 2>&1 ||
    refuse "pinned key is not a readable public key: $path"
  # Byte-exact (cmp, not $(...), so NUL bytes and trailing data count): no relabelled
  # private body, no extra blocks, no trailing or header-less material, no reformatting.
  cmp -s -- "$work/canonical.pub" "$work/pinned.pub" ||
    refuse "pinned key is not the canonical PEM of one public key: $path"
  public_text=$(openssl pkey -pubin -in "$work/canonical.pub" -noout -text_pub 2>/dev/null) || public_text=''
  [[ $public_text == 'ED25519 Public-Key:'* ]] || refuse "pinned key is not ed25519: $path"
}
if [[ -n $check_key ]]; then
  [[ -z $pubkey && -z $pubkey_dir ]] || usage
  pin_key "$check_key"
  echo "pinned key ok: $check_key"
  exit 0
fi

sig=${sig:-$receipt.sig}
[[ -n $pubkey || -n $pubkey_dir ]] || usage
[[ -n $runner_name ]] || refuse 'RUNNER_NAME is empty'
snapshot "$receipt" "$work/receipt.json" 65536
snapshot "$sig" "$work/receipt.sig" 64
(( $(stat -c %s -- "$work/receipt.sig") == 64 )) || refuse 'signature is not 64 bytes (ed25519)'
if [[ -z $pubkey ]]; then
  host=$(jq -er '.host | strings' "$work/receipt.json" 2>/dev/null) || refuse 'receipt host unreadable'
  [[ $host =~ ^[a-z0-9-]+$ ]] || refuse 'receipt host is not a plain host name'
  pubkey=$pubkey_dir/$host.pub
fi
pin_key "$pubkey"

openssl pkeyutl -verify -pubin -inkey "$work/canonical.pub" -rawin -in "$work/receipt.json" -sigfile "$work/receipt.sig" >/dev/null 2>&1 ||
  refuse 'signature does not verify against the pinned key'
# Only the signed private copy is interpreted from here on.
field() { jq -er --arg k "$1" '.[$k] | select(type == "string" or type == "number")' "$work/receipt.json" 2>/dev/null || refuse "field $1 missing"; }
[[ $(field schema) == neverhuman.lan-runner-receipt.v1 ]] || refuse 'unknown schema'
key_id=$(openssl pkey -pubin -in "$work/canonical.pub" -outform DER | sha256sum | cut -d' ' -f1)
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
