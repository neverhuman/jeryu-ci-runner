#!/usr/bin/env bash
# Reproducible host preparation. Installs this controller without enabling job lanes.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
nh_require_root
[[ ${1:-} == --prepare ]] || { echo 'Usage: provision.sh --prepare (does not enable runner lanes)' >&2; exit 2; }
[[ -e /dev/kvm ]] || exit 2
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
apt-get update -qq
apt-get install -y --no-install-recommends qemu-system-x86 qemu-utils cloud-image-utils jq nftables
getent passwd neverhuman-vm >/dev/null || useradd --system --home-dir "$NH_STATE" --shell /usr/sbin/nologin neverhuman-vm
usermod -a -G kvm neverhuman-vm
install -d -m 0755 /opt/neverhuman-actions "$NH_STATE/images"
install -d -m 0700 "$NH_CONFIG" "$NH_STATE/receipts"
install -d -m 0750 -o neverhuman-vm -g neverhuman-vm "$NH_STATE/jobs"
source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for file in common.sh egress.sh prepare-image.sh qualify.sh api.sh launch.sh pilot-register.sh; do
  [[ $source_dir/$file == /opt/neverhuman-actions/$file ]] || install -m 0644 "$source_dir/$file" "/opt/neverhuman-actions/$file"
done
install -m 0644 "$source_dir/systemd/neverhuman-actions-egress.service" /etc/systemd/system/
install -m 0644 "$source_dir/systemd/neverhuman-runner@.service" /etc/systemd/system/
if [[ ! -f $NH_CLOUD_IMAGE ]]; then
  curl -fL --retry 3 --output "$NH_CLOUD_IMAGE.part" https://cloud-images.ubuntu.com/noble/20260926/noble-server-cloudimg-amd64.img
  printf '%s  %s\n' "$NH_CLOUD_SHA256" "$NH_CLOUD_IMAGE.part" | sha256sum -c -
  mv "$NH_CLOUD_IMAGE.part" "$NH_CLOUD_IMAGE"
fi
printf '%s  %s\n' "$NH_CLOUD_SHA256" "$NH_CLOUD_IMAGE" | sha256sum -c -
chmod 0444 "$NH_CLOUD_IMAGE"
systemctl daemon-reload
echo 'Controller prepared; job lanes remain disabled until credentials, access and required checks qualify'
