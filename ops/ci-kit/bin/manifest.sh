#!/usr/bin/env bash
# jeryu ci-kit: content manifest shared by seal.sh, vendor.sh and verify.sh.
# Source-only.

readonly CI_KIT_MANIFEST=MANIFEST.sha256

# Print the sorted "sha256  path" manifest of every file in a kit directory,
# excluding the manifest itself. Symlinks and special files are rejected so a
# copy cannot point outside the kit.
ci_kit_manifest() {
  local dir="$1" path
  if [[ ! -d "${dir}" || -L "${dir}" ]]; then
    printf 'ci-kit: not a kit directory: %s\n' "${dir}" >&2
    return 1
  fi
  if [[ -n "$(find "${dir}" -mindepth 1 ! -type f ! -type d -print -quit)" ]]; then
    printf 'ci-kit: kit may hold only regular files: %s\n' "${dir}" >&2
    return 1
  fi
  (
    cd "${dir}"
    find . -type f ! -path "./${CI_KIT_MANIFEST}" -printf '%P\n' | LC_ALL=C sort |
      while IFS= read -r path; do
        sha256sum -- "${path}"
      done
  )
}

# The kit content hash is the sha256 of its manifest.
ci_kit_hash() {
  local manifest
  manifest="$(ci_kit_manifest "$1")" || return 1
  printf '%s\n' "${manifest}" | sha256sum | awk '{print $1}'
}
