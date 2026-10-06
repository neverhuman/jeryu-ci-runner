#!/usr/bin/env bash
# Offline, deterministic: an unpinned binary or archive over the size limit must be flagged (and so
# held), whatever the model says; pinning its sha256 in the diff, or staying small or textual, clears it.
#   test/binary-payload.sh      exit 0 when every case behaves
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
echo dummy >"$t/token"
git init -q "$t/r"; g() { git -C "$t/r" -c user.name=t -c user.email=t@t "$@"; }
echo base >"$t/r/README"; g add -A; g commit -qm base; base="$(g rev-parse HEAD)"

blobs() { # head -> _blobs output for base..head
  g diff "$base...$1" >"$t/diff.patch"
  REDTEAM_MAX_BLOB_BYTES=1000000 REDTEAM_STATE="$t/state" JERYU_BASE="${JERYU_BASE:-https://forge.invalid}" JERYU_TOKEN_FILE="$t/token" \
    "$here/pr-redteam" _blobs "$t/r/.git" "$base" "$1" "$t/diff.patch"
}
fail=0
check() { # name expected-count head
  local n; n="$(blobs "$3" | grep -c . || true)"
  if [ "$n" = "$2" ]; then echo "ok   $1: $n flagged"; else echo "FAIL $1: $n flagged, expected $2"; fail=1; fi
}

g checkout -qb big-archive "$base"
head -c 2000000 /dev/urandom >"$t/r/locked-cargo-home.tar.gz"; g add -A; g commit -qm big
check "2 MB unpinned archive" 1 "$(g rev-parse HEAD)"

digest="$(sha256sum "$t/r/locked-cargo-home.tar.gz" | cut -c1-64)"
echo "$digest  locked-cargo-home.tar.gz" >"$t/r/SHA256SUMS"; g add -A; g commit -qm pin
check "same archive, digest pinned in the diff" 0 "$(g rev-parse HEAD)"

g checkout -qb big-binary-noext "$base"
head -c 2000000 /dev/urandom >"$t/r/payload"; g add -A; g commit -qm blob
check "2 MB binary, no extension" 1 "$(g rev-parse HEAD)"

g checkout -qb small-archive "$base"
head -c 50000 /dev/urandom >"$t/r/fixture.tar.gz"; g add -A; g commit -qm small
check "50 KB archive (under limit)" 0 "$(g rev-parse HEAD)"

g checkout -qb big-text "$base"
awk 'BEGIN { for (i = 0; i < 125000; i++) print "plain text line" }' >"$t/r/data.txt"; g add -A; g commit -qm text
check "2 MB plain text" 0 "$(g rev-parse HEAD)"

[ "$fail" = 0 ] && echo "BINARY PAYLOAD PASS" || { echo "BINARY PAYLOAD FAIL"; exit 1; }
