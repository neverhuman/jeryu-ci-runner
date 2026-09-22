#!/usr/bin/env bash
# Regenerate the canonical kit manifest after editing ops/ci-kit/. Bump
# ops/ci-kit/VERSION with any content change; consumers pin version + hash.
set -euo pipefail
kit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=ops/ci-kit/bin/manifest.sh
source "${kit_dir}/bin/manifest.sh"
ci_kit_manifest "${kit_dir}" > "${kit_dir}/${CI_KIT_MANIFEST}"
printf 'ci-kit %s sealed: sha256=%s\n' "$(<"${kit_dir}/VERSION")" \
  "$(ci_kit_hash "${kit_dir}")"
