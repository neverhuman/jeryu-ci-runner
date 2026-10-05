#!/usr/bin/env bash
# Only QEMU's dedicated uid is affected. Existing host firewall tables are preserved.
set -euo pipefail
[[ $(id -u) == 0 ]] || exit 2
uid=$(id -u neverhuman-vm)
[[ $uid =~ ^[0-9]+$ && $uid -gt 0 ]] || exit 2
rules=$(mktemp)
trap 'rm -f "$rules"' EXIT
# The one approved local endpoint is the existing forge HTTPS transport.
# All other private, host-loopback, metadata and public ingress access is denied.
if nft list table inet neverhuman_actions >/dev/null 2>&1; then
  printf 'delete table inet neverhuman_actions\n' >> "$rules"
fi
cat >> "$rules" <<RULES
table inet neverhuman_actions {
 chain output {
  type filter hook output priority -10; policy accept;
  meta skuid $uid ct state established,related accept
  meta skuid $uid ip daddr 162.218.217.123 tcp dport 443 accept
  meta skuid $uid ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4, 162.218.217.123 } counter reject
  meta skuid $uid meta nfproto ipv6 counter reject
 }
}
RULES
nft --check -f "$rules"
nft -f "$rules"
install -m 0644 "$rules" /etc/neverhuman-actions/egress.nft
