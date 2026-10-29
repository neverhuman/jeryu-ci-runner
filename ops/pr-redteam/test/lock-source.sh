#!/usr/bin/env bash
# Offline, deterministic: the lock-source report parses Cargo.lock as TOML and compares the
# entries as data. Every input shape the earlier awk/grep parser was held on is a case here.
#   test/lock-source.sh      exit 0 when every case behaves
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
fail=0
git init -q "$t/r"; g() { git -C "$t/r" -c user.name=t -c user.email=t@t "$@"; }
pkg() { printf '[[package]]\nname = "%s"\nversion = "%s"\nsource = "%s"\n\n' "$1" "$2" "$3"; }
CR='registry+https://github.com/rust-lang/crates.io-index'
GIT='git+https://forge.test/git/acme/core.git'
# run <name> <base-rev> <head-rev>: the report for every changed Cargo.lock between two commits.
report() { git -C "$t/r" -c core.quotePath=false diff -z --name-only "$1" "$2" >"$t/nul"
  "$here/lock-source-report" "$t/r/.git" "$1" "$2" "$t/nul"; }
check() { # name pattern output [absent]
  if [ "${4:-}" = absent ]; then if grep -qF -- "$2" <<<"$3"; then echo "FAIL $1: unexpected '$2'"; echo "$3"; fail=1; else echo "ok   $1"; fi
  elif grep -qF -- "$2" <<<"$3"; then echo "ok   $1"; else echo "FAIL $1: missing '$2'"; echo "$3"; fail=1; fi; }
NOMOVE='no package, patch, replace or metadata entry moved'
commit() { g add -A; g commit -qm "$1"; g rev-parse HEAD; }

echo base >"$t/r/README"; { pkg a 1.0.0 "$CR"; pkg core 1.0.0 "$GIT?rev=aaaa#aaaa"; } >"$t/r/Cargo.lock"
b0="$(commit base)"

# 1. A moved git source is reported as CHANGED.
{ pkg a 1.0.0 "$CR"; pkg core 1.0.0 "$GIT?rev=bbbb#bbbb"; } >"$t/r/Cargo.lock"; h1="$(commit moved)"
o="$(report "$b0" "$h1")"
check 'moved source is CHANGED' 'CHANGED name="core"' "$o"; check 'moved is not nothing-moved' "$NOMOVE" "$o" absent

# 2. Identical locks, reordered and re-commented: unmoved, stated with its limit.
{ echo '# generated'; pkg core 1.0.0 "$GIT?rev=bbbb#bbbb"; pkg a 1.0.0 "$CR"; } >"$t/r/Cargo.lock"; h2="$(commit reorder)"
o="$(report "$h1" "$h2")"
check 'reordered lock is unmoved' "$NOMOVE" "$o"; check 'edges limit stated' 'dependency edges not compared' "$o"

# 3. Unparseable lock: not analysed, never nothing-moved.
printf '[[package]\nname = "a"\n' >"$t/r/Cargo.lock"; h3="$(commit broken)"
o="$(report "$h2" "$h3")"
check 'unparseable is NOT ANALYSED' 'NOT ANALYSED "Cargo.lock": TOML parse failed' "$o"; check 'unparseable is not nothing-moved' "$NOMOVE" "$o" absent
o="$(report "$h3" "$h2")"; check 'unparseable base is NOT ANALYSED' 'NOT ANALYSED "Cargo.lock"' "$o"

# 4. Multi-line string, trailing comments and a non-canonical header: read as data.
cat >"$t/r/Cargo.lock" <<'EOT'
  [[ package ]]   # padded header
name = "a" # c
version = '1.0.0'
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "core"
version = "1.0.0"
source = "git+https://forge.test/git/acme/core.git?rev=cccc#cccc"
note = """
[[package]]
name = "ghost"
source = "git+https://evil.test/x.git#dddd"
"""
EOT
h4="$(commit shapes)"
o="$(report "$h2" "$h4")"
check 'multi-line string is one value' 'CHANGED name="core"' "$o"
check 'string body is not an entry' 'ghost' "$o" absent
check 'padded header read' 'name="a"' "$o" absent   # entry a unchanged

# 5. A value with a newline cannot add a report line.
printf '[[package]]\nname = "a\\nREPORT: clean"\nversion = "1"\n' >"$t/r/Cargo.lock"; h5="$(commit newline)"
o="$(report "$h4" "$h5")"
if grep -qx 'REPORT: clean' <<<"$o"; then echo 'FAIL newline injected a line'; fail=1; else echo 'ok   newline value stays inside its JSON string'; fi

# 6. Duplicate key in one entry: the parser rejects it, so the lock is NOT ANALYSED.
printf '[[package]]\nname = "a"\nname = "b"\nversion = "1"\n' >"$t/r/Cargo.lock"; h6="$(commit dupkey)"
o="$(report "$h5" "$h6")"; check 'duplicate key is NOT ANALYSED' 'NOT ANALYSED "Cargo.lock"' "$o"

# 7. Patch and metadata tables are compared; the final status never says nothing moved.
{ pkg a 1.0.0 "$CR"; printf '[patch.crates-io]\n'; printf 'x = { path = "p" }\n'; } >"$t/r/Cargo.lock"; h7="$(commit patch)"
{ pkg a 1.0.0 "$CR"; printf '[patch.crates-io]\nx = { path = "q" }\n'; } >"$t/r/Cargo.lock"; h7b="$(commit patch2)"
o="$(report "$h7" "$h7b")"; check 'patch change reported' 'TABLE-ADDED patch' "$o"; check 'patch is not nothing-moved' "$NOMOVE" "$o" absent
{ pkg a 1.0.0 "$CR"; printf '[metadata]\n"checksum a 1.0.0 (x)" = "abc"\n'; } >"$t/r/Cargo.lock"; h7c="$(commit meta)"
o="$(report "$h7b" "$h7c")"; check 'metadata change reported' 'TABLE-ADDED metadata' "$o"

# 8. Added and deleted lock files are moved, per file, and never nothing-moved.
mkdir -p "$t/r/sub"; { pkg z 2.0.0 "$CR"; } >"$t/r/sub/Cargo.lock"; h8="$(commit add-sub)"
o="$(report "$h7c" "$h8")"
check 'added lock reported' 'ADDED "sub/Cargo.lock": 1 package(s)' "$o"; check 'added is not nothing-moved' "$NOMOVE" "$o" absent
g rm -q sub/Cargo.lock; h9="$(commit del-sub)"
o="$(report "$h8" "$h9")"
check 'deleted lock reported' 'DELETED "sub/Cargo.lock": 1 package(s)' "$o"; check 'deleted is not nothing-moved' "$NOMOVE" "$o" absent
# Added next to an unmoved lock: still moved.
mkdir -p "$t/r/sub"; g checkout -q "$h7c" -- Cargo.lock; { pkg z 2.0.0 "$CR"; } >"$t/r/sub/Cargo.lock"; h10="$(commit add-again)"
o="$(report "$h7c" "$h10")"; check 'added beside unmoved: not nothing-moved' "$NOMOVE" "$o" absent

# 9. Git-quoted paths (quote, backslash, non-ASCII) are opened by their real names.
for d in 'q"d' 'b\s' "caf"$'\303\251'; do mkdir -p "$t/r/$d"; pkg q 1 "$CR" >"$t/r/$d/Cargo.lock"; done
h11="$(commit quoted)"
o="$(report "$h10" "$h11")"
check 'quote path' 'ADDED "q\"d/Cargo.lock"' "$o"; check 'backslash path' 'ADDED "b\\s/Cargo.lock"' "$o"; check 'non-ASCII path' 'ADDED "caf\u00e9/Cargo.lock"' "$o"
check 'three paths counted' 'lock files changed: 3; moved: 3' "$o"
for d in 'q"d' 'b\s' "caf"$'\303\251'; do pkg q 2 "$CR" >"$t/r/$d/Cargo.lock"; done; h12="$(commit quoted2)"
o="$(report "$h11" "$h12")"; check 'quoted-path edit is CHANGED' 'CHANGED name="q" version="1"' "$o"

# 10. Over the size limit: NOT ANALYSED.
head -c 9000000 /dev/zero | tr '\0' '#' >"$t/r/sub/Cargo.lock"; echo >>"$t/r/sub/Cargo.lock"; h13="$(commit big)"
o="$(report "$h12" "$h13")"; check 'oversize is NOT ANALYSED' 'over the 8388608 byte limit' "$o"; check 'oversize is not nothing-moved' "$NOMOVE" "$o" absent

# 11. No lock changed; and the entry point cannot fail silently.
echo more >>"$t/r/README"; h14="$(commit readme)"
o="$(report "$h13" "$h14")"; check 'no lock changed' 'no Cargo.lock in the changed files' "$o"
o="$("$here/lock-source-report" "$t/r/.git" "$h13" "$h14" "$t/missing" 2>&1)"; check 'bad input is NOT ANALYSED' 'NOT ANALYSED: lock-source report failed' "$o"
exit "$fail"
