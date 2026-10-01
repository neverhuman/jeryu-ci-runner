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
