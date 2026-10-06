#!/usr/bin/env bash
# Guest-side verifier for the signed lan-ci receipt written by launch.sh (receipt.sh).
# Standalone: needs bash, jq, openssl and sha256sum; never sources the host controller.
#   verify-receipt.sh (--pubkey FILE | --pubkey-dir DIR) [--receipt FILE] [--sig FILE]
#                     [--runner-name NAME] [--max-age SECONDS] [--boot-window SECONDS]
#                     [--now EPOCH] [--boot-time EPOCH]
# The trust anchor is a published, pinned public key (--pubkey-dir selects <host>.pub
# from the receipt's host, which the signature then binds). Checks: ed25519 signature,
# schema, key_id, runner_name == instance == $RUNNER_NAME, issued no later than now+60s and
# no older than --max-age (default 86400), and that this guest booted within
# --boot-window seconds after issue (default 900; 0 disables). Prints the verified receipt
# JSON on success. Exit 0 verified, 1 refused, 2 usage.
set -euo pipefail
receipt=/etc/neverhuman-ci/receipt.json sig='' pubkey='' pubkey_dir=''
runner_name=${RUNNER_NAME:-} max_age=86400 boot_window=900 now='' boot_time='' skew=60
usage() { sed -n '3,6p' "$0" >&2; exit 2; }
refuse() { echo "receipt refused: $*" >&2; exit 1; }
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
for value in "$max_age" "$boot_window" "${now:-0}" "${boot_time:-0}"; do [[ $value =~ ^[0-9]+$ ]] || usage; done
for tool in jq openssl sha256sum; do command -v "$tool" >/dev/null || refuse "missing tool $tool"; done
[[ -f $receipt && -f $sig ]] || refuse "receipt or signature absent ($receipt)"
[[ -n $runner_name ]] || refuse 'RUNNER_NAME is empty'
if [[ -z $pubkey ]]; then
  host=$(jq -er '.host | strings' "$receipt" 2>/dev/null) || refuse 'receipt host unreadable'
  [[ $host =~ ^[a-z0-9-]+$ ]] || refuse 'receipt host is not a plain host name'
  pubkey=$pubkey_dir/$host.pub
fi
[[ -f $pubkey ]] || refuse "pinned public key absent: $pubkey"
openssl pkeyutl -verify -pubin -inkey "$pubkey" -rawin -in "$receipt" -sigfile "$sig" >/dev/null 2>&1 ||
  refuse 'signature does not verify against the pinned key'
# Only signed bytes are interpreted from here on.
field() { jq -er --arg k "$1" '.[$k] | select(type == "string" or type == "number")' "$receipt" 2>/dev/null || refuse "field $1 missing"; }
[[ $(field schema) == neverhuman.lan-runner-receipt.v1 ]] || refuse 'unknown schema'
key_id=$(openssl pkey -pubin -in "$pubkey" -outform DER | sha256sum | cut -d' ' -f1)
[[ $(field key_id) == "$key_id" ]] || refuse 'key_id does not match the pinned key'
[[ $(field runner_name) == "$runner_name" ]] || refuse "runner_name is not $runner_name"
[[ $(field instance) == "$runner_name" ]] || refuse 'instance does not equal runner_name'
issued=$(field issued_at_epoch)
[[ $issued =~ ^[0-9]+$ ]] || refuse 'issued_at_epoch is not an integer'
now=${now:-$(date -u +%s)}
(( issued <= now + skew )) || refuse 'issued in the future'
(( now - issued <= max_age )) || refuse "older than $max_age seconds"
if (( boot_window > 0 )); then
  boot_time=${boot_time:-$(awk '/^btime / {print $2}' /proc/stat)}
  [[ $boot_time =~ ^[0-9]+$ ]] || refuse 'guest boot time unreadable'
  (( boot_time + skew >= issued )) || refuse 'guest booted before the receipt was issued'
  (( boot_time - issued <= boot_window )) || refuse "guest booted more than $boot_window seconds after issue"
fi
jq -c . "$receipt"
