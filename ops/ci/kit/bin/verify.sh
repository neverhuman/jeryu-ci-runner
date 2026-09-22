#!/usr/bin/env bash
# Check a vendored ci-kit copy against its pin; any drift fails.
# Usage:
#   verify.sh <repo-root> [--canonical <kit-dir>]
#       checks <repo-root>/ops/ci/kit against <repo-root>/ops/ci/kit.pin and,
#       with --canonical, that the pin names that kit's current content.
#   verify.sh --sealed <kit-dir>
#       checks a canonical kit's MANIFEST.sha256 matches its content.
set -euo pipefail
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/ci-kit/bin/manifest.sh
source "${self_dir}/manifest.sh"

fail() {
  printf 'ci-kit drift: %s\n' "$*" >&2
  exit 1
}

check_sealed() {
  local kit="$1"
  [[ -f "${kit}/${CI_KIT_MANIFEST}" ]] || fail "missing ${kit}/${CI_KIT_MANIFEST}"
  [[ -f "${kit}/VERSION" ]] || fail "missing ${kit}/VERSION"
  if ! diff -u "${kit}/${CI_KIT_MANIFEST}" <(ci_kit_manifest "${kit}") >&2; then
    fail "${kit} content does not match its ${CI_KIT_MANIFEST}"
  fi
}

pin_field() {
  local pin="$1" key="$2" value
  value="$(awk -F '=' -v key="${key}" '
    $1 == key { count += 1; sub(/^[^=]*=/, ""); value = $0 }
    END { if (count != 1) exit 1; print value }
  ' "${pin}")" || fail "${pin} must set ${key} exactly once"
  printf '%s\n' "${value}"
}

if [[ "${1:-}" == "--sealed" && $# -eq 2 ]]; then
  check_sealed "$2"
  printf 'ci-kit %s sealed ok: sha256=%s\n' "$(<"$2/VERSION")" "$(ci_kit_hash "$2")"
  exit 0
fi
if [[ $# -ne 1 && ! ( $# -eq 3 && "$2" == "--canonical" ) ]]; then
  printf 'usage: %s <repo-root> [--canonical <kit-dir>] | --sealed <kit-dir>\n' "$0" >&2
  exit 2
fi

root="$1"
kit="${root}/ops/ci/kit"
pin="${root}/ops/ci/kit.pin"
[[ -f "${pin}" && ! -L "${pin}" ]] || fail "missing pin ${pin}"
[[ -d "${kit}" && ! -L "${kit}" ]] || fail "missing vendored kit ${kit}"
pinned_version="$(pin_field "${pin}" version)"
pinned_hash="$(pin_field "${pin}" sha256)"
[[ "${pinned_hash}" =~ ^[0-9a-f]{64}$ ]] || fail "${pin} sha256 is not a sha256"

check_sealed "${kit}"
actual_hash="$(ci_kit_hash "${kit}")"
[[ "${actual_hash}" == "${pinned_hash}" ]] ||
  fail "${kit} hash ${actual_hash} != pinned ${pinned_hash}"
[[ "$(<"${kit}/VERSION")" == "${pinned_version}" ]] ||
  fail "${kit}/VERSION $(<"${kit}/VERSION") != pinned ${pinned_version}"

if [[ $# -eq 3 ]]; then
  canonical="$3"
  check_sealed "${canonical}"
  canonical_hash="$(ci_kit_hash "${canonical}")"
  [[ "${canonical_hash}" == "${pinned_hash}" ]] ||
    fail "pin ${pinned_version} (${pinned_hash}) is behind canonical $(<"${canonical}/VERSION") (${canonical_hash}); re-run vendor.sh"
fi
printf 'ci-kit %s ok: sha256=%s\n' "${pinned_version}" "${pinned_hash}"
