#!/usr/bin/env bash
# Offline: a git-pin bump gets upstream/ (log, diff, pull requests, branch verdict) from a stand-in
# forge remote, and a rev that is not on the named upstream branch is reported as such.
#   test/upstream-evidence.sh      exit 0 when every case behaves
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../pr-redteam"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
fail() { echo "not ok - $1" >&2; exit 1; }
for f in upstream_pins upstream_pin_evidence upstream_evidence; do
  eval "$(sed -n "/^$f() {/,/^}/p" "$script")"
done
upstream_max_pins=6 upstream_max_bytes=100000 upstream_max_commits=50 upstream_fetch_timeout=20
state="$t/state"; base=https://forge.invalid
# The stand-in forge: a local bare repository; the real function builds https://<forge>/git/... only.
upstream_remote() { echo "$t/forge/$1.git"; }
api() { code=200; body="$stub_pulls"; }

u() { git -C "$t/up" -c user.name=t -c user.email=t@t "$@"; }
mkdir -p "$t/up" "$t/forge/acme"; git init -q -b main "$t/up"
mkdir -p "$t/up/core/src"; printf '[package]\nname = "acme-core"\n' >"$t/up/core/Cargo.toml"
echo one >"$t/up/core/src/lib.rs"; u add -A; u commit -qm one; r1="$(u rev-parse HEAD)"
echo two >"$t/up/core/src/lib.rs"; u commit -qam two; r2="$(u rev-parse HEAD)"
u checkout -qb side "$r1"; echo side >"$t/up/other"; u add -A; u commit -qm side; rs="$(u rev-parse HEAD)"
u checkout -q main; echo three >"$t/up/core/src/lib.rs"; u commit -qam three; r3="$(u rev-parse HEAD)"
git clone -q --bare "$t/up" "$t/forge/acme/core.git"
stub_pulls="{\"items\":[{\"number\":9,\"state\":\"merged\",\"title\":\"two\",\"head_ref\":\"feat\",\"base_ref\":\"main\",\"head_sha\":\"$r2\"}]}"

git init -q -b main "$t/dep"; d() { git -C "$t/dep" -c user.name=t -c user.email=t@t "$@"; }
pin() { # rev branch
  cat >"$t/dep/Cargo.toml" <<EOF
[dependencies]
acme-core = { git = "http://127.0.0.1:8787/git/acme/core.git", branch = "$2", rev = "$1" }
EOF
  cat >"$t/dep/Cargo.lock" <<EOF
[[package]]
name = "acme-core"
version = "1.0.0"
source = "git+http://127.0.0.1:8787/git/acme/core.git?branch=$2#$1"
EOF
}
pin "$r1" main; d add -A; d commit -qm base; b="$(d rev-parse HEAD)"

run() { # rev branch -> prints the review dir
  pin "$1" "$2"; d commit -qam bump; local o="$t/rev-$1-$2"; mkdir -p "$o"
  upstream_evidence "$t/dep/.git" "$b" "$(d rev-parse HEAD)" "$o" acme >/dev/null
  d reset -q --hard "$b"; echo "$o"
}

o="$(run "$r3" main)"; cat "$o/upstream/SUMMARY.txt" >/dev/null
dir="$o/upstream/acme_core-${r3:0:12}"
[ "$(jq -r .status "$dir/pin.json")" = merged-tip ] || fail "tip rev: $(cat "$dir/pin.json")"
grep -q "commit $r2" "$dir/log.txt" || fail "log lists the commits between old and new"
grep -q '^+three' "$dir/diff.patch" || fail "diff of the imported crate"
[ "$(jq -r '.[0].number' "$dir/pulls.json")" = 9 ] || fail "commit's pull request: $(cat "$dir/pulls.json")"
[ "$(jq -r '.[0].head_ref' "$dir/pulls.json")" = feat ] || fail "pull request branch"

o="$(run "$r2" main)"; dir="$o/upstream/acme_core-${r2:0:12}"
[ "$(jq -r .status "$dir/pin.json")" = ancestor-of-tip ] || fail "ancestor rev: $(cat "$dir/pin.json")"

o="$(run "$rs" main)"; dir="$o/upstream/acme_core-${rs:0:12}"
[ "$(jq -r .status "$dir/pin.json")" = NOT-ON-BRANCH ] || fail "rev on another branch: $(cat "$dir/pin.json")"
grep -q NOT-ON-BRANCH "$o/upstream/SUMMARY.txt" || fail "summary reports the rev not on the branch"

o="$(run "$(printf 'f%.0s' {1..40})" main)"
grep -q 'rev-not-on-forge' "$o/upstream/SUMMARY.txt" || fail "unknown rev reported: $(cat "$o/upstream/SUMMARY.txt")"

# A change that moves no pin gets no upstream/.
echo x >"$t/dep/readme"; d add -A; d commit -qm doc; o="$t/plain"; mkdir -p "$o"
upstream_evidence "$t/dep/.git" "$b" "$(d rev-parse HEAD)" "$o" acme
[ ! -e "$o/upstream" ] || fail "no pin moved but upstream/ exists"

# Pin extraction reads the dependency-sources pin and ignores hosts outside /git/owner/name.
d reset -q --hard "$b"
printf 'core|tag-a|%s|refs/heads/x\n' "$r1" >"$t/dep/hosted-pin-refs.tsv"; d add -A; d commit -qm tsv; tb="$(d rev-parse HEAD)"
printf 'core|tag-a|%s|refs/heads/x\n' "$r3" >"$t/dep/hosted-pin-refs.tsv"; d commit -qam tsv2
[ "$(upstream_pins "$t/dep/.git" "$tb" HEAD acme | cut -f1-3)" = "$(printf 'acme/core\t%s\t%s' "$r1" "$r3")" ] || fail "tsv pin"
echo 'x = { git = "https://evil.example/elsewhere.git", rev = "abcdef1" }' >"$t/dep/Cargo.toml"; d commit -qam evil
[ -z "$(upstream_pins "$t/dep/.git" "$tb" HEAD acme | grep evil || true)" ] || fail "foreign URL ignored"
echo "UPSTREAM EVIDENCE PASS"
