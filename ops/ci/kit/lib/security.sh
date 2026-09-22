#!/usr/bin/env bash
# jeryu ci-kit: security-lane primitives shared by every family repo.
# Source-only. Canonical source: jeryu-ci-runner ops/ci-kit/.

# Stream every tracked and untracked (non-ignored) text file into gitleaks.
# Paths under target/, node_modules/ and dist/ are skipped; extra glob
# patterns given as arguments are skipped too (e.g. 'apps/web/dist/*').
ci_kit_secret_scan() {
  local -a skip=('target/*' 'node_modules/*' 'dist/*' "$@")
  local path pattern skipped
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    gitleaks detect --no-git --redact --verbose
    return
  fi
  {
    git ls-files -z
    git ls-files --others --exclude-standard -z
  } | sort -zu | while IFS= read -r -d '' path; do
    [[ -f "${path}" ]] || continue
    skipped=0
    for pattern in "${skip[@]}"; do
      # shellcheck disable=SC2053
      if [[ "${path}" == ${pattern} ]]; then
        skipped=1
        break
      fi
    done
    (( skipped == 0 )) || continue
    if LC_ALL=C grep -Iq . "${path}"; then
      printf '\n===== %s =====\n' "${path}"
      cat "${path}"
    fi
  done | gitleaks detect --pipe --redact --verbose
}

# Fail when any .env file exists outside .git.
ci_kit_forbid_env_files() {
  if find . -path './.git' -prune -o -name '.env' -type f -print | grep -q .; then
    printf 'security check failed: committed .env file found\n' >&2
    return 1
  fi
}
