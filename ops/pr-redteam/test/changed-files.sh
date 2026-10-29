#!/usr/bin/env bash
# Offline, deterministic: the changed-file list is NUL-delimited and unquoted, so a lock file at a
# non-ASCII, quote or backslash path is listed by its real name and resolves at the head.
#   test/changed-files.sh      exit 0 when every case behaves
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
echo dummy >"$t/token"
git init -q "$t/r"; g() { git -C "$t/r" -c user.name=t -c user.email=t@t "$@"; }
echo base >"$t/r/README"; g add -A; g commit -qm base; base="$(g rev-parse HEAD)"
mkdir -p "$t/r/caf"$'\303\251' "$t/r/q\"d" "$t/r/b\\s"
for d in "caf"$'\303\251' 'q"d' 'b\s'; do echo x >"$t/r/$d/Cargo.lock"; done
g add -A; g commit -qm locks; head="$(g rev-parse HEAD)"
fail=0
list="$(REDTEAM_STATE="$t/state" JERYU_BASE=https://forge.invalid JERYU_TOKEN_FILE="$t/token" "$here/pr-redteam" _files "$t/r/.git" "$base" "$head" "$t/files.nul")"
for want in "caf"$'\303\251/Cargo.lock' 'q"d/Cargo.lock' 'b\s/Cargo.lock'; do
  if grep -qxF -- "$want" <<<"$list"; then echo "ok   listed: $want"; else echo "FAIL not listed unquoted: $want"; fail=1; fi
done
while IFS= read -r -d '' f; do
  git -C "$t/r" cat-file -e "$head:$f" 2>/dev/null || { echo "FAIL does not resolve: $f"; fail=1; }
done <"$t/files.nul"
[ "$(tr -cd '\0' <"$t/files.nul" | wc -c)" = 3 ] || { echo "FAIL expected 3 NUL-terminated paths"; fail=1; }
exit "$fail"
