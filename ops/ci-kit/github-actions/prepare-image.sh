#!/usr/bin/env bash
# Builds a credential-free immutable VM base. Does not register a runner.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
nh_require_root
exec 9>"$NH_STATE/image-build.lock"
flock -n 9 || { echo 'Image build already owned' >&2; exit 2; }
[[ ! -e $NH_GOLD_IMAGE ]] || { echo 'Base already exists; qualify or explicitly version a replacement' >&2; exit 2; }
[[ -e /dev/kvm ]] || exit 2
printf '%s  %s\n' "$NH_CLOUD_SHA256" "$NH_CLOUD_IMAGE" | sha256sum -c -
[[ -f $NH_CONFIG/guest-key ]] || ssh-keygen -q -t ed25519 -N '' -f "$NH_CONFIG/guest-key"
chmod 0600 "$NH_CONFIG/guest-key"
NH_INSTANCE="image-$NH_HOST-$(date -u +%Y%m%d%H%M%S)"
NH_UNIT="neverhuman-$NH_INSTANCE"
NH_PORT=22600
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
packages: [build-essential, ca-certificates, curl, git, jq, unzip, zip, xz-utils, zstd, python3, python3-pip, python3-venv, pkg-config, libssl-dev, libicu74, liblttng-ust1, libkrb5-3, libunwind8, libnuma1, libgtk-3-dev, libwebkit2gtk-4.1-dev, libxdo-dev, libayatana-appindicator3-dev, librsvg2-dev, patchelf, docker.io, docker-buildx, shellcheck, nodejs, npm, postgresql-client, rsync]
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
  '{phase:"image-prepared",host:$host,image_sha256:$image_sha256,cloud_sha256:$cloud_sha256,runner_version:$runner_version,time:$time,runner_registered:false}' \
  > "$NH_STATE/receipts/image-prepared.json"
echo "Credential-free runner VM prepared on $NH_HOST"
