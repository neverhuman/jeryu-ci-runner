#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pr-gate-config.sh — the site configuration every pr-gate script reads. Sourced, never run.
#
# Everything that names a particular site -- the forge, the credential, the owners and their
# checkout roots, repository-specific exceptions -- lives in one file of KEY=VALUE lines:
#
#   ${PR_GATE_CONFIG:-$HOME/.config/jeryu/pr-gate.env}
#
# The file is read, never run as shell: one KEY=VALUE per line, blank lines and # comments ignored,
# one pair of surrounding single or double quotes stripped from the value, nothing expanded except a
# leading "~/" (the running user's home). Only keys that start with PR_GATE_, GATE_RUNNER_,
# GATE_INSTALL_ or JERYU_ are taken; any other key (PATH, LD_PRELOAD, ...) is ignored. A variable the
# caller already set always wins over the file, so a systemd Environment= line or a drop-in still
# overrides it for one unit. See ../pr-gate.env.example for every key.
# ---------------------------------------------------------------------------

# Fill unset settings from the site file. A missing file is not an error here: each script says
# which setting it needs and that it is not configured.
pr_gate_load_config() {
  local file="${PR_GATE_CONFIG:-$HOME/.config/jeryu/pr-gate.env}" line key value
  # shellcheck disable=SC2034  # read by the sourcing script, to name the file in its messages
  PR_GATE_CONFIG_FILE="$file"
  [[ -r "$file" && -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
    [[ "$key" =~ ^(PR_GATE_|GATE_RUNNER_|GATE_INSTALL_|JERYU_) ]] || continue
    [[ "$key" != PR_GATE_CONFIG && "$key" != PR_GATE_CONFIG_FILE ]] || continue
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
    # shellcheck disable=SC2088  # a literal "~/" in the data, expanded here by hand
    [[ "$value" != "~/"* ]] || value="$HOME/${value#"~/"}"
    [[ -n "${!key+set}" ]] || printf -v "$key" '%s' "$value"
  done <"$file"
}

# A path setting: absolute as given, "~/x" or a relative "x" under $HOME.
# shellcheck disable=SC2088  # a literal "~/" in the data, expanded here by hand
pr_gate_path() { # value
  case "$1" in
    "") return 0;;
    /*) printf '%s' "$1";;
    "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}";;
    *) printf '%s/%s' "$HOME" "$1";;
  esac
}

# The value for KEY in a space-separated list of KEY=VALUE words, or nothing.
pr_gate_lookup() { # list key
  local - word
  set -f
  for word in $1; do
    [[ "${word%%=*}" == "$2" && "$word" == *=* ]] && { printf '%s' "${word#*=}"; return 0; }
  done
  return 1
}

# Site-owned source closure, not PR-controlled configuration. Each exact owner/repo maps to
# comma-separated same-owner sibling names, or '-' for no siblings. Validate the whole map so a
# typo cannot silently leave some repositories on a different policy. No paths, globs or duplicates.
pr_gate_dependencies_valid() { # map
  local - word key deps dep
  local name='[A-Za-z0-9_][A-Za-z0-9_.-]*'
  local -A keys=() names=()
  set -f
  for word in $1; do
    [[ "$word" == *=* ]] || return 1
    key=${word%%=*} deps=${word#*=}
    [[ "$key" =~ ^$name/$name$ && -z "${keys[$key]+set}" ]] || return 1
    keys[$key]=1
    [[ "$deps" != - ]] || continue
    [[ "$deps" =~ ^$name(,$name)*$ ]] || return 1
    names=()
    for dep in ${deps//,/ }; do
      [[ "$dep" != "${key#*/}" && -z "${names[$dep]+set}" ]] || return 1
      names[$dep]=1
    done
  done
}

# True when NAME is one of the space-separated words (globs) in LIST.
pr_gate_listed() { # list name...
  local - list=$1 pattern name; shift
  set -f
  for pattern in $list; do
    for name in "$@"; do
      # shellcheck disable=SC2053  # a glob, by design
      [[ "$name" == $pattern ]] && return 0
    done
  done
  return 1
}

# Advertised gate environments. Keep this vocabulary aligned with the forge's heartbeat validator
# (PR_GATE_KNOWN_CAPABILITIES). Whitespace separates names; unknown and repeated names are
# configuration errors. Prints the names as a JSON array, in the order given.
PR_GATE_KNOWN_CAPABILITIES="host-ci"
pr_gate_capabilities() {
  local - capability
  local -A known=() seen=()
  local names=()
  set -f
  for capability in $PR_GATE_KNOWN_CAPABILITIES; do known[$capability]=1; done
  for capability in ${GATE_RUNNER_CAPABILITIES:-}; do
    if [[ -z "${known[$capability]+set}" ]]; then
      printf 'GATE_RUNNER_CAPABILITIES: unknown capability %s (expected one of: %s)\n' "$capability" "$PR_GATE_KNOWN_CAPABILITIES" >&2
      return 2
    fi
    if [[ -n "${seen[$capability]+set}" ]]; then
      printf 'GATE_RUNNER_CAPABILITIES: duplicate capability %s\n' "$capability" >&2
      return 2
    fi
    seen[$capability]=1
    names+=("$capability")
  done
  jq -nc '$ARGS.positional' --args "${names[@]}"
}

# Escape a literal URL prefix for use inside an ERE alternation.
pr_gate_ere_quote() { # literal
  printf '%s' "$1" | sed -E 's/[][\.^$*+?(){}|]/\\&/g'
}

# Which Cargo.lock sources the locked-crate prefetch may fetch online, as one ERE of URL prefixes
# the prefetch anchors each lock row to. crates.io always; then the site's configured prefixes
# (PR_GATE_LOCK_SOURCES), which is where a family's declared publishing mirror is named; then, for
# each owner this host gates, that owner's own path on the governed forge -- <forge>/git/<owner>/,
# the exact remote discover_repos requires of a gated repository, and the source Cargo records for a
# crate locked from it. A family that publishes through a mirror locks some rows from the mirror and
# the rest from that canonical path; with only the mirror configured, one canonical row made the
# prefetch skip the whole lockfile, and the offline recipe then failed on a crate nobody had
# fetched. Nothing wider is admitted: not another owner's path on the same forge, not another host,
# and no URL carrying credentials -- a configured prefix or forge URL that does is a configuration
# error, refused here rather than handed to git.
pr_gate_lock_sources_ere() { # forge-base configured-prefixes owner...
  local base="${1%/}" configured="$2"
  shift 2
  local - prefix owner
  local -A seen=()
  local ere='registry\+https://github\.com/rust-lang/crates\.io-index|sparse\+https://index\.crates\.io/'
  set -f
  for prefix in $configured; do
    [[ "$prefix" != *@* ]] || {
      printf 'PR_GATE_LOCK_SOURCES must name no credentials: %s\n' "$prefix" >&2
      return 2
    }
    ere+="|$(pr_gate_ere_quote "$prefix")"
  done
  if [[ -n "$base" ]]; then
    [[ "$base" != *@* ]] || {
      printf 'the forge URL must name no credentials: %s\n' "$base" >&2
      return 2
    }
    for owner in "$@"; do
      [[ "$owner" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ && -z "${seen[$owner]+set}" ]] || continue
      seen[$owner]=1
      ere+="|$(pr_gate_ere_quote "git+$base/git/$owner/")"
    done
  fi
  printf '%s' "$ere"
}
