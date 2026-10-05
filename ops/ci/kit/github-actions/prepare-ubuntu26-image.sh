#!/usr/bin/env bash
# Builds a credential-free immutable VM base. Does not register a runner.
set -euo pipefail
# shellcheck source=common.sh
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
nh_require_root
NH_CLOUD_SHA256=8800651811af9a85465ad1d552add729947bb16488dddb4a9b5305a3d97332b2
NH_CLOUD_IMAGE=$NH_STATE/images/resolute-20260927-amd64.img
NH_GOLD_IMAGE=$NH_STATE/images/runner-ubuntu26-x64.qcow2
[[ ! -e $NH_STATE/receipts/image-ubuntu26-prepared.json ]] || exit 2
[[ $(awk '/MemAvailable:/ {print $2}' /proc/meminfo) -ge 12582912 ]] || exit 2
[[ $(df --output=avail -BG "$NH_STATE" | tail -n1 | tr -dc '0-9') -ge 100 ]] || exit 2
nft list table inet neverhuman_actions >/dev/null
if [[ ! -f $NH_CLOUD_IMAGE ]]; then
  curl -fL --retry 3 --output "$NH_CLOUD_IMAGE.part" https://cloud-images.ubuntu.com/resolute/20260927/resolute-server-cloudimg-amd64.img
  printf '%s  %s\n' "$NH_CLOUD_SHA256" "$NH_CLOUD_IMAGE.part" | sha256sum -c -
  mv "$NH_CLOUD_IMAGE.part" "$NH_CLOUD_IMAGE"
  chmod 0444 "$NH_CLOUD_IMAGE"
fi
nh_require_root
exec 9>"$NH_STATE/image-build.lock"
flock -n 9 || { echo 'Image build already owned' >&2; exit 2; }
[[ ! -e $NH_GOLD_IMAGE ]] || { echo 'Base already exists; qualify or explicitly version a replacement' >&2; exit 2; }
[[ -e /dev/kvm ]] || exit 2
printf '%s  %s\n' "$NH_CLOUD_SHA256" "$NH_CLOUD_IMAGE" | sha256sum -c -
[[ -f $NH_CONFIG/guest-key ]] || ssh-keygen -q -t ed25519 -N '' -f "$NH_CONFIG/guest-key"
chmod 0600 "$NH_CONFIG/guest-key"
NH_INSTANCE="image-ubuntu26-$NH_HOST-$(date -u +%Y%m%d%H%M%S)"
NH_UNIT="neverhuman-$NH_INSTANCE"
NH_PORT=22613
nh_prepare_job_dir
trap 'nh_vm_stop' EXIT
qemu-img create -q -f qcow2 -F qcow2 -b "$NH_CLOUD_IMAGE" "$NH_JOB/disk.qcow2" 80G
pubkey=$(<"$NH_CONFIG/guest-key.pub")
cat > "$NH_JOB/user-data" <<CLOUD
#cloud-config
ssh_pwauth: false
groups: [docker]
users:
  - name: runner
    groups: [sudo, docker]
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - $pubkey
package_update: true
packages: [build-essential, ca-certificates, curl, git, jq, unzip, zip, xz-utils, zstd, python3, python3-pip, python3-venv, pkg-config, libssl-dev, libkrb5-3, libunwind8, libnuma1, patchelf, docker.io, docker-buildx, shellcheck, nodejs, npm, postgresql-client, rsync]
write_files:
  - path: /usr/local/sbin/prepare-ci-image
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      install -d -o runner -g runner /opt/actions-runner /opt/hostedtoolcache
      curl -fL --retry 3 -o /tmp/runner.tar.gz https://github.com/actions/runner/releases/download/v$NH_RUNNER_VERSION/actions-runner-linux-x64-$NH_RUNNER_VERSION.tar.gz
      printf '%s  /tmp/runner.tar.gz\\n' '$NH_RUNNER_SHA256' | sha256sum -c -
      tar xzf /tmp/runner.tar.gz -C /opt/actions-runner
      chown -R runner:runner /opt/actions-runner
      /opt/actions-runner/bin/installdependencies.sh
      source /etc/os-release
      test "\$VERSION_ID" = "26.04"
      sudo -u runner /opt/actions-runner/bin/Runner.Listener --version
      rm /tmp/runner.tar.gz
      systemctl enable --now docker
      touch /var/lib/neverhuman-image-ready
runcmd:
  - [/usr/local/sbin/prepare-ci-image]
CLOUD
nh_seed "$NH_JOB/user-data"
nh_vm_start "$NH_JOB/disk.qcow2" "$NH_JOB/seed.img" 8 8192
deadline=$((SECONDS + 1800))
until nh_guest_ssh 'test -f /var/lib/neverhuman-image-ready' >/dev/null 2>&1; do
  if [[ $SECONDS -gt $deadline ]] || ! systemctl is-active --quiet "$NH_UNIT"; then
    echo "Image preparation failed; inspect $NH_JOB/serial.log" >&2
    exit 1
  fi
  sleep 5
done
nh_guest_ssh 'sudo cloud-init clean --logs; sudo poweroff' || true
shutdown_deadline=$((SECONDS + 60))
while systemctl is-active --quiet "$NH_UNIT" && [[ $SECONDS -lt $shutdown_deadline ]]; do sleep 1; done
systemctl is-active --quiet "$NH_UNIT" && { echo 'Image did not shut down cleanly' >&2; exit 1; }
# Flatten the overlay so no mutable cloud-image backing chain remains.
qemu-img convert -q -O qcow2 "$NH_JOB/disk.qcow2" "$NH_GOLD_IMAGE.part"
chmod 0444 "$NH_GOLD_IMAGE.part"
mv "$NH_GOLD_IMAGE.part" "$NH_GOLD_IMAGE"
sha=$(sha256sum "$NH_GOLD_IMAGE" | cut -d' ' -f1)
jq -n --arg host "$NH_HOST" --arg image_sha256 "$sha" --arg runner_version "$NH_RUNNER_VERSION" \
  --arg cloud_sha256 "$NH_CLOUD_SHA256" --arg time "$(date -u +%FT%TZ)" \
  '{phase:"image-ubuntu26-prepared",ubuntu_version:"26.04",host:$host,image_sha256:$image_sha256,cloud_sha256:$cloud_sha256,runner_version:$runner_version,time:$time,runner_registered:false}' \
  > "$NH_STATE/receipts/image-ubuntu26-prepared.json"
rm -- "$NH_JOB/disk.qcow2" "$NH_JOB/seed.img"
echo "Credential-free runner VM prepared on $NH_HOST"
