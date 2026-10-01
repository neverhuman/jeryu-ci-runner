#!/usr/bin/env bash
set -euo pipefail

# BEGIN GENERATED JANKURAI PIN — DO NOT EDIT
export JERYU_JANKURAI_SOURCE_REPO="https://git.neverhuman.org/git/jeryu/jankurai.git"
export JERYU_JANKURAI_VERSION="jankurai 1.6.11"
export JERYU_JANKURAI_SHA256="b05c03bcb0fb2d004d3daa303ae236b8985b39e393567e8f8d274cd9f6f89103"
export JERYU_JANKURAI_SOURCE_REV="2b8312215573eb225075ca0556f1208ae5265b8c"
export JERYU_JANKURAI_SOURCE_TAG="v1.6.11-deadlang-precision-split.4"
export JERYU_JANKURAI_SOURCE_TREE="bc15c67053db2d1e87e25e71276766d055130701"
export JERYU_JANKURAI_SOURCE_ARCHIVE_SHA256="2c8fbbd71a73c978b58bf038f30008b937a16969ec52a528f21ce2d7fa404cf6"
export JERYU_JANKURAI_CARGO_LOCK_SHA256="b9acb981c326226a687d0b6703e4f7ee303148e9e1a6dda1aa03d77988820f6a"
export JERYU_JANKURAI_RUST_TOOLCHAIN="1.95.0"
export JERYU_JANKURAI_RUSTC_VERSION="rustc 1.95.0 (59807616e 2026-04-14)"
export JERYU_JANKURAI_CARGO_VERSION="cargo 1.95.0 (f2d3ce0bd 2026-03-21)"
export JERYU_JANKURAI_TARGET_TRIPLE="x86_64-unknown-linux-gnu"
export JERYU_JANKURAI_BUILD_MODE="oci-vendor-locked-offline-workspace-member-v2"
export JERYU_JANKURAI_PACKAGE_PATH="crates/jankurai"
export JERYU_JANKURAI_BUILDER_IMAGE="rust@sha256:d7482085ff5b415f84dba5647ae71606650bdef00db7aeb69f4b3d170c3e4082"
export JERYU_JANKURAI_BUILDER_IMAGE_ID="sha256:d7482085ff5b415f84dba5647ae71606650bdef00db7aeb69f4b3d170c3e4082"
export JERYU_JANKURAI_LINKER_VERSION="GNU ld (GNU Binutils for Debian) 2.40"
export JERYU_JANKURAI_GLIBC_VERSION="ldd (Debian GLIBC 2.36-9+deb12u14) 2.36"
export JERYU_JANKURAI_VENDOR_FILES_SHA256="a7e332f4495d9748ea020ae8ee37c4240f0f035059799bd3dc74497437143d99"
export JERYU_JANKURAI_VENDOR_FILE_COUNT="14889"
export JERYU_JANKURAI_CARGO_CONFIG_SHA256="b8982c761d62e447f2d1653c199d2d58e6b2de6c5a6f8ddba3d38e47b7f863d6"
export JERYU_JANKURAI_BUILD_ENVIRONMENT="CARGO_NET_OFFLINE=true,HOME=/tmp,LANG=C,LC_ALL=C,SOURCE_DATE_EPOCH=0,TZ=UTC"
export JERYU_JANKURAI_RUSTFLAGS="--remap-path-prefix=/opt/jeryu/jankurai=/jankurai-build/source --remap-path-prefix=/opt/jeryu/vendor=/jankurai-build/vendor --remap-path-prefix=/opt/jeryu/target=/jankurai-build/target --remap-path-prefix=/usr/local/cargo=/jankurai-build/cargo"
export JERYU_JANKURAI_BUILD_COMMAND="cargo install --locked --offline --path /opt/jeryu/jankurai/crates/jankurai --root /opt/jeryu/out --bin jankurai"
export JERYU_JANKURAI_BUILD_CONTEXT_SHA256="c8303ff86f53ccbcde8b64a1b921cbb61031a2f801ab58440b044fabf76be4a2"
# END GENERATED JANKURAI PIN

# shellcheck source=ops/ci/hosted-git-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hosted-git-env.sh"

# Jankurai executes proof-plan commands through a login shell. Login startup
# files are allowed to reorder PATH, so resolving the auditor by name can select
# an unrelated host installation during proof replay even when the parent CI
# process put the pinned Cargo bin first. Keep every library consumer bound to
# the repository's pinned Cargo installation instead.
readonly JERYU_JANKURAI_BIN="${CARGO_HOME:-${HOME}/.cargo}/bin/jankurai"
# Jankurai 1.6.11 fingerprints the repository policy even when --fail-under
# supplies a stricter run-local threshold. Keep the fleet floor centralized so
# candidate and protected-main ratchet reports receive the identical override.
readonly JERYU_FLEET_MINIMUM_SCORE=91

audit_effective_floor() {
  local policy_path="$1"
  local configured_floor
  configured_floor="$({
    awk -F '=' '
      /^[[:space:]]*minimum_score[[:space:]]*=/ {
        count += 1
        value = $2
        sub(/[[:space:]]*#.*/, "", value)
        gsub(/[[:space:]]/, "", value)
        if (value !~ /^[0-9]+$/) exit 2
        floor = value
      }
      END {
        if (count != 1) exit 3
        print floor
      }
    ' "${policy_path}"
  })" || {
    printf 'audit policy must contain one integer minimum_score: %s\n' \
      "${policy_path}" >&2
    return 1
  }
  if (( configured_floor > JERYU_FLEET_MINIMUM_SCORE )); then
    printf '%s\n' "${configured_floor}"
  else
    printf '%s\n' "${JERYU_FLEET_MINIMUM_SCORE}"
  fi
}

validate_jankurai_binary() {
  local physical
  if [[ "${JERYU_JANKURAI_BIN}" != /* ||
        ! -f "${JERYU_JANKURAI_BIN}" ||
        -L "${JERYU_JANKURAI_BIN}" ||
        ! -x "${JERYU_JANKURAI_BIN}" ||
        "$(/usr/bin/stat -c '%h' -- "${JERYU_JANKURAI_BIN}" 2>/dev/null || true)" != 1 ]]; then
    printf 'pinned Jankurai must be an absolute executable one-link regular file: %s\n' \
      "${JERYU_JANKURAI_BIN}" >&2
    return 1
  fi
  physical="$(/usr/bin/readlink -f -- "${JERYU_JANKURAI_BIN}")" || {
    printf 'cannot resolve pinned Jankurai binary: %s\n' \
      "${JERYU_JANKURAI_BIN}" >&2
    return 1
  }
  if [[ "${physical}" != "${JERYU_JANKURAI_BIN}" ]]; then
    printf 'pinned Jankurai path is not physical: %s\n' \
      "${JERYU_JANKURAI_BIN}" >&2
    return 1
  fi
}

# Shared helpers (require_tool, require_jankurai, jankurai, security and job
# resolution) come from the pinned ci-kit copy; see ops/ci/kit.pin.
ci_kit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kit"
# shellcheck source=ops/ci/kit/lib/jankurai.sh
source "${ci_kit_dir}/lib/jankurai.sh"
# shellcheck source=ops/ci/kit/lib/security.sh
source "${ci_kit_dir}/lib/security.sh"
# shellcheck source=ops/ci/kit/lib/jobs.sh
source "${ci_kit_dir}/lib/jobs.sh"
unset ci_kit_dir

# jeryu-tool's pin renderer owns this wrapper in every ops/ci/lib.sh and
# appends it when missing, so it stays here even though the kit defines the
# same function.
jankurai() {
  require_jankurai || return 1
  command "${JERYU_GOVERNED_JANKURAI_BIN}" "$@"
}
