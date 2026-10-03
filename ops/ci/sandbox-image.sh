#!/usr/bin/env bash
# Shared resolution of the live sandbox matrix base image. Keep this file source-only.
set -euo pipefail

# The one pin of record for the escape matrix base image: the Docker Hub
# multi-arch index digest for alpine:3.20, looked up 2026-10-02. A digest is
# the identity, so a warm host never has to ask a registry what a tag means.
JERYU_SANDBOX_IMAGE_DEFAULT='alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc'

# Print the image the matrix must run. JERYU_SANDBOX_IMAGE wins, then IMAGE,
# then the pin. Any override must name a digest for the same reason the pin
# does: a tag can be repointed under us (see ops/ci/ensure-jankurai.sh, which
# pins its builder image the same way).
jeryu_sandbox_image_resolve() {
  local image="${JERYU_SANDBOX_IMAGE:-${IMAGE:-${JERYU_SANDBOX_IMAGE_DEFAULT}}}"
  if [[ ! "${image}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    printf 'sandbox matrix image must be pinned by digest, got %s: set JERYU_SANDBOX_IMAGE to <ref>@sha256:<64 hex> (default %s)\n' \
      "${image}" "${JERYU_SANDBOX_IMAGE_DEFAULT}" >&2
    return 1
  fi
  printf '%s\n' "${image}"
}

# Make the pinned image present locally, pulling only when it is not already
# there: a warm gate host reaches no registry at all. A cold host still needs
# the registry once.
jeryu_sandbox_image_ensure() {
  local image="$1"
  if docker image inspect "${image}" >/dev/null 2>&1; then
    printf 'sandbox matrix image cached: %s\n' "${image}" >&2
    return 0
  fi
  printf 'sandbox matrix image absent, pulling once: %s\n' "${image}" >&2
  docker pull "${image}"
}
