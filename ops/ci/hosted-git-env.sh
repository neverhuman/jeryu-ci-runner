#!/usr/bin/env bash
# Source-only Cargo Git transport environment. Cargo does not apply its own
# `[env]` table early enough to govern the Git fetch child, so host CI sources
# this helper before invoking Cargo.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'hosted-git-env.sh must be sourced\n' >&2
  exit 2
fi

hosted_git_env_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
hosted_git_env_overlay="${hosted_git_env_root}/.cargo/hosted-gitconfig" || return 1
hosted_git_env_overlay_sha256='c030d7738dc385e64ae844b9ccb6334bb840a7f8c0f7768fe1f9203df316254c' || return 1
hosted_git_env_caller_global="${GIT_CONFIG_GLOBAL-}" || return 1

# Command-scoped configuration, tracing, askpass, and TLS overrides can bypass
# the reviewed URL/credential policy or disclose credentials. Scrub them before
# inspecting or exporting any Git configuration used by Cargo.
# Prefix expansion is a Bash builtin and needs no /dev/fd process substitution.
# Empty prefix expansions are harmless; any readonly scrub target rejects source.
hosted_git_env_injected='' || return 1
for hosted_git_env_injected in \
  GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM \
  GIT_ASKPASS SSH_ASKPASS GIT_SSH GIT_SSH_COMMAND GIT_PROXY_COMMAND \
  GIT_SSL_CAINFO GIT_SSL_CAPATH GIT_SSL_NO_VERIFY GIT_CURL_VERBOSE \
  GIT_EXEC_PATH GIT_TEMPLATE_DIR GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR \
  GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
  HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
  http_proxy https_proxy all_proxy no_proxy \
  CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR \
  "${!GIT_CONFIG_KEY_@}" "${!GIT_CONFIG_VALUE_@}" "${!GIT_TRACE@}"; do
  [[ -n "${hosted_git_env_injected}" ]] || continue
  builtin unset -- "${hosted_git_env_injected}" 2>/dev/null || {
    printf 'hosted Git environment scrub failed\n' >&2
    return 1
  }
done || return 1

if [[ ! -f "${hosted_git_env_overlay}" || -L "${hosted_git_env_overlay}" ||
      "$(/usr/bin/stat -c '%h' -- "${hosted_git_env_overlay}")" != 1 ||
      "$(/usr/bin/sha256sum "${hosted_git_env_overlay}" | /usr/bin/awk '{print $1}')" != \
        "${hosted_git_env_overlay_sha256}" ]]; then
  printf 'hosted Git overlay is not the exact reviewed one-link policy: %s\n' \
    "${hosted_git_env_overlay}" >&2
  return 1
fi

if [[ -n "${hosted_git_env_caller_global}" ]]; then
  if [[ "${hosted_git_env_caller_global}" != /* ||
        ! -f "${hosted_git_env_caller_global}" ||
        -L "${hosted_git_env_caller_global}" ||
        "$(/usr/bin/stat -c '%h' -- "${hosted_git_env_caller_global}")" != 1 ]]; then
    printf 'caller GIT_CONFIG_GLOBAL must be an absolute one-link regular file\n' >&2
    return 1
  fi
  if ! /usr/bin/cmp --silent -- "${hosted_git_env_caller_global}" \
    "${hosted_git_env_overlay}"; then
    printf 'caller GIT_CONFIG_GLOBAL differs from the exact reviewed hosted policy\n' >&2
    return 1
  fi
fi
builtin export GIT_CONFIG_GLOBAL="${hosted_git_env_overlay}" 2>/dev/null || {
  printf 'hosted Git environment export failed\n' >&2
  return 1
}

builtin export GIT_CONFIG_NOSYSTEM=1 2>/dev/null || {
  printf 'hosted Git environment export failed\n' >&2
  return 1
}
builtin export CARGO_NET_GIT_FETCH_WITH_CLI=true 2>/dev/null || {
  printf 'hosted Git environment export failed\n' >&2
  return 1
}
builtin export GIT_TERMINAL_PROMPT=0 2>/dev/null || {
  printf 'hosted Git environment export failed\n' >&2
  return 1
}
builtin unset -- hosted_git_env_root hosted_git_env_overlay hosted_git_env_overlay_sha256 \
  hosted_git_env_caller_global hosted_git_env_injected 2>/dev/null || {
  printf 'hosted Git environment cleanup failed\n' >&2
  return 1
}
