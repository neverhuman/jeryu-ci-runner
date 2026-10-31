#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pr-gate-cargo-plugin-install.sh — put a Cargo plugin into ~/.cargo/bin inside a gate drain.
#
# ~/.cargo/bin is on the recipe PATH, so every file in it is part of a gate's input identity. A plugin
# written there while a gate runs ends that attempt as "inputs_changed" however green its recipe was
# (jeryu-ci-runner#193 attempt 25c471 and #188, 2026-10-31: both passed with score 94 and were
# discarded because cargo-gov03-rnk08-t0745 was linked, then its target rewritten, mid-gate).
# This is the producer's way in: it copies the plugin's bytes with pr-gate-tool-update.sh, so the
# install waits for the slots to drain exactly as any other tool update does. Nothing is frozen or
# ignored; the strict identity check still fails any install made outside the drain.
#
#   pr-gate-cargo-plugin-install.sh [--timeout SECONDS] [--update-timeout SECONDS] NAME SOURCE
#
# NAME is a bare cargo-<name> file name. SOURCE is a regular executable file or a symlink to one; its
# bytes are copied (never linked), so a later rewrite of SOURCE cannot change the installed plugin.
# Exit status is the updater's: 75 means nothing was installed and the producer may try again.
# ---------------------------------------------------------------------------
set -euo pipefail
here="$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")"
usage() { printf 'usage: %s [--timeout SECONDS] [--update-timeout SECONDS] NAME SOURCE\n' "$(basename -- "$0")" >&2; exit 2; }

passthrough=()
while (($#)); do
  case "$1" in
    --timeout|--update-timeout) [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]] || usage; passthrough+=("$1" "$2"); shift 2;;
    --) shift; break;;
    -*) usage;;
    *) break;;
  esac
done
(($# == 2)) || usage
name=$1 source_file=$2
[[ "$name" =~ ^cargo-[A-Za-z0-9][A-Za-z0-9._-]*$ && "$name" != *..* ]] \
  || { printf 'not a cargo plugin name: %s\n' "$name" >&2; exit 2; }
resolved=$(realpath -e -- "$source_file" 2>/dev/null) && [[ -f "$resolved" && -x "$resolved" ]] \
  || { printf 'not an executable file: %s\n' "$source_file" >&2; exit 2; }
destination_dir="${CARGO_HOME:-$HOME/.cargo}/bin"
[[ -d "$destination_dir" && ! -L "$destination_dir" ]] \
  || { printf 'not a plain directory: %s\n' "$destination_dir" >&2; exit 2; }

# install(1) writes a fresh file and never follows a link at the destination.
exec "$here/pr-gate-tool-update.sh" "${passthrough[@]}" -- \
  install -m 0755 -T -- "$resolved" "$destination_dir/$name"
