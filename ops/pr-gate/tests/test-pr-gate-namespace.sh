#!/usr/bin/env bash
# Exercise the production workspace selection without credentials or root.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
runner=${1:-$script_dir/pr-gate-runner.sh}
# shellcheck source=ops/pr-gate/bin/pr-gate-config.sh
source "$script_dir/pr-gate-config.sh"
# The site's repositories that must see their physical path (PR_GATE_PHYSICAL_PATH_REPOS).
# shellcheck disable=SC2034  # read by the production block sourced below
PHYSICAL_PATH_REPOS="acme/acme-ops other/*-host-tests"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
awk '
  /^worker_root="\$run" enter=\(\)/ { copying=1 }
  /^sccache_env=/ { copying=0 }
  copying { print }
' "$runner" > "$fixture/selection.sh"
[[ -s "$fixture/selection.sh" ]]

check() (
  local name=$1 owner=$2 repo=$3 run=$4 CANONICAL_PATH=$5 mount_available=$6 expected=$7 sandbox=${8:-0}
  local number=1   # named in the sandbox line the block logs
  export CANONICAL_PATH
  local worker_root
  local -a enter
  canon_dir() { printf '%s/canonical' "$fixture"; }
  say() { printf '%s\n' "$*" >> "$fixture/selection.log"; }
  sudo() { printf 'called\n' >> "$fixture/sudo.log"; [[ "$mount_available" == yes ]]; }
  : > "$fixture/sudo.log"
  # shellcheck disable=SC1091
  source "$fixture/selection.sh"
  if [[ "$expected" == physical ]]; then
    [[ "$worker_root" == "$run" && ${#enter[@]} == 0 ]] || {
      printf 'FAIL %s: host-visible physical path required, selected %s\n' "$name" "$worker_root" >&2
      exit 1
    }
  else
    [[ "$worker_root" == "$(canon_dir "$owner")" && ${#enter[@]} -gt 0 ]]
  fi
  if [[ "$owner/$repo" == acme/acme-ops || "$owner/$repo" == other/*-host-tests ]]; then
    [[ ! -s "$fixture/sudo.log" ]] || { printf '%s attempted a private mount\n' "$owner/$repo" >&2; exit 1; }
  fi
  printf 'PASS %s\n' "$name"
)
check 'configured host service paths' acme acme-ops "$fixture/slot5" 1 yes physical
check 'configured glob of host service paths' other web-host-tests "$fixture/slot5" 1 yes physical
check 'ordinary cache namespace' acme acme-deploy "$fixture/slot5" 1 yes canonical
check 'same name, other owner is ordinary' gate-a acme-ops "$fixture/slot5" 1 yes canonical
check 'slot zero stays physical' acme acme-ops "$fixture/canonical" 1 yes physical
check 'explicit namespace disable' acme acme-deploy "$fixture/slot5" 0 yes physical
check 'unavailable mount capability' acme acme-deploy "$fixture/slot5" 1 no physical
# A contribution runs in the site's sandbox, which brings its own view of the filesystem: the runner
# builds no mount namespace of its own for it, not even on a slot that would otherwise get one.
: > "$fixture/selection.log"
check 'a contribution never enters our namespace' acme acme-deploy "$fixture/slot5" 1 yes physical 1
grep -q 'is a contribution: running it in the configured sandbox' "$fixture/selection.log" \
  || { printf 'the sandbox selection was not reported\n' >&2; exit 1; }
