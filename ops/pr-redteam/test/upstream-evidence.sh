#!/usr/bin/env bash
# The functions under test read globals set here, so SC2034 does not apply to this file.
# shellcheck disable=SC2034
# Offline: a git-pin bump gets upstream/ (log, diff, pull requests, branch verdict) from a stand-in
# forge, and nothing the change's author writes picks what is fetched or what counts as verified.
#   test/upstream-evidence.sh      exit 0 when every case behaves
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../pr-redteam"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
fail() { echo "not ok - $1" >&2; exit 1; }
ok() { echo "ok - $1"; }
for f in upstream_manifest_pins upstream_url_map upstream_pins upstream_tag upstream_remote upstream_git \
    upstream_capped upstream_pin_evidence upstream_evidence; do
  eval "$(sed -n "/^$f() {/,/^}/p" "$script")"
  declare -F "$f" >/dev/null || fail "$f not found in pr-redteam"
done
upstream_max_pins=6 upstream_max_bytes=100000 upstream_max_commits=50 upstream_fetch_timeout=20
upstream_max_branches=8 upstream_max_pull_pages=10
state="$t/state"; me=reviewer
# The stand-in forge is a directory served over file://; the real upstream_remote builds
# $base/git/<owner>/<name>.git from it. Manifests name the forge by its host, forge.test.
base="file://$t/forge"; forge_host=forge.test
token_file="$t/token"; printf 'dummytoken' >"$token_file"; chmod 600 "$token_file"

# Ambient credentials that must never be used: a global helper that records any call and fails, and
# a netrc. Every git command below, the code under test included, runs with them in place.
mkdir -p "$t/home"
cat >"$t/ambient.gitconfig" <<EOF
[credential]
	helper = "!f() { echo called >>'$t/ambient-called'; exit 1; }; f"
EOF
printf 'machine 127.0.0.1 login ambient password netrcsecret\n' >"$t/home/.netrc"; chmod 600 "$t/home/.netrc"
export GIT_CONFIG_GLOBAL="$t/ambient.gitconfig" HOME="$t/home" GIT_TERMINAL_PROMPT=0

# The forge API: default branch, branch list with protection, and paged pull requests.
stub_default=main stub_release_protected=false pulls_more=false stub_pulls='{"items":[]}'
api() {
  echo "$2" >>"$t/api.log"; code=200
  case "$2" in
    */refs) body="$(jq -nc --argjson rp "$stub_release_protected" '[
        {name: "main", kind: "branch", protected: true},
        {name: "release/v1", kind: "branch", protected: $rp},
        {name: "side", kind: "branch", protected: false},
        {name: "v1", kind: "tag", protected: true}]')" ;;
    */pulls\?*) body="$(jq -c --argjson more "$pulls_more" '. + {page: {has_more: $more}}' <<<"$stub_pulls")" ;;
    /api/v1/repos/*) body="$(jq -nc --arg d "$stub_default" '{default_branch: $d}')" ;;
    *) code=404; body='{}' ;;
  esac
}

# The upstream repository acme/core: main r1-r2-r3, an unprotected `side` branch and release/v1.
u() { git -C "$t/up" -c user.name=t -c user.email=t@t "$@"; }
git init -q -b main "$t/up"
mkdir -p "$t/up/core/src" "$t/up/other"
printf '[package]\nname = "acme-core"\n' >"$t/up/core/Cargo.toml"; printf '[package]\nname = "other"\n' >"$t/up/other/Cargo.toml"
echo one >"$t/up/core/src/lib.rs"; u add -A; u commit -qm one; r1="$(u rev-parse HEAD)"
echo two >"$t/up/core/src/lib.rs"; echo two >"$t/up/other/x"; u add -A; u commit -qm two; r2="$(u rev-parse HEAD)"
u checkout -qb side "$r1"; echo side >"$t/up/core/side"; u add -A; u commit -qm side; rs="$(u rev-parse HEAD)"
u checkout -qb release/v1 "$r1"; echo rel >"$t/up/core/rel"; u add -A; u commit -qm rel; rr="$(u rev-parse HEAD)"
u checkout -q main; echo three >"$t/up/core/src/lib.rs"; u commit -qam three; r3="$(u rev-parse HEAD)"
mkdir -p "$t/forge/git/acme"; git clone -q --bare "$t/up" "$t/forge/git/acme/core.git"
stub_pulls="{\"items\":[{\"number\":9,\"state\":\"merged\",\"title\":\"two\",\"head_ref\":\"feat\",\"base_ref\":\"main\",\"head_sha\":\"$r2\"}]}"

# A dependent repository per case: put files, snap a commit, gather evidence between two commits.
D=""
dep() { D="$t/dep-$1"; git init -q -b main "$D"; }
put() { mkdir -p "$(dirname "$D/$1")"; cat >"$D/$1"; }
snap() { git -C "$D" add -A; git -C "$D" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; git -C "$D" rev-parse HEAD; }
evidence() { # base head -> review dir
  local o; o="$(mktemp -d "$t/out-XXXXXX")"; : >"$t/api.log"
  upstream_evidence "$D/.git" "$1" "$2" "$o" acme "${budget:-100000}"; echo "$o"
}
inline() { # rev [branch]: the forge URL, inline form
  printf '[package]\nname = "dep"\n\n[dependencies]\nacme-core = { git = "https://forge.test/git/acme/core.git"%s, rev = "%s" }\n' \
    "${2:+, branch = \"$2\"}" "$1"
}
pin_of() { echo "$1/upstream/acme@core-${2:0:12}/pin.json"; } # review-dir rev
field() { jq -r ".$2" "$1"; }

# 1. A forward bump onto the default branch's tip: verified, against the default branch.
dep fwd; inline "$r1" | put Cargo.toml
printf '[[package]]\nname = "acme-core"\nversion = "1.0.0"\nsource = "git+https://forge.test/git/acme/core.git?rev=%s#%s"\n' "$r1" "$r1" | put Cargo.lock
b="$(snap base)"
inline "$r3" | put Cargo.toml
printf '[[package]]\nname = "acme-core"\nversion = "1.0.0"\nsource = "git+https://forge.test/git/acme/core.git?rev=%s#%s"\n' "$r3" "$r3" | put Cargo.lock
o="$(evidence "$b" "$(snap bump)")"; p="$(pin_of "$o" "$r3")"; dir="$(dirname "$p")"
[ "$(field "$p" status)" = merged-tip ] || fail "tip rev: $(cat "$p")"
[ "$(field "$p" verified)" = true ] && [ "$(field "$p" checked_branch)" = main ] && [ "$(field "$p" checked_branch_kind)" = default ] \
  && [ "$(field "$p" checked_branch_author_supplied)" = false ] || fail "checked branch recorded: $(cat "$p")"
[[ "$(field "$p" tips_fetched_at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || fail "fetch time recorded"
grep -q "commit $r2" "$dir/log.txt" || fail "log lists the commits between old and new"
grep -q '^+three' "$dir/diff.patch" || fail "diff of the imported crate"
! grep -q "other/x" "$dir/diff.patch" || fail "diff limited to the named crate: $(cat "$dir/note.txt" 2>/dev/null; grep "^diff" "$dir/diff.patch")"
[ "$(jq -r '.[0].number' "$dir/pulls.json")" = 9 ] && [ "$(jq -r '.[0].head_ref' "$dir/pulls.json")" = feat ] || fail "commit's pull request: $(cat "$dir/pulls.json")"
grep -qx '/api/v1/repos/acme%2Fcore' "$t/api.log" && grep -qx '/api/v1/repos/acme%2Fcore/refs' "$t/api.log" \
  && grep -qx '/api/v1/repos/acme%2Fcore/pulls?state=all&per_page=100&page=1' "$t/api.log" || fail "forge API paths: $(cat "$t/api.log")"
[ "$(grep -c . "$o/upstream/SUMMARY.txt" | tr -d ' ')" -gt 0 ] && grep -q "acme/core ${r3:0:12}: merged-tip (branch main, default)" "$o/upstream/SUMMARY.txt" \
  || fail "summary row: $(cat "$o/upstream/SUMMARY.txt")"
ok 'forward bump onto the default branch tip is merged-tip, checked against the forge default'

# 2. An ancestor of the default branch tip.
inline "$r2" | put Cargo.toml; git -C "$D" checkout -q "$b" -- Cargo.lock
o="$(evidence "$b" "$(snap anc)")"
[ "$(field "$(pin_of "$o" "$r2")" status)" = ancestor-of-tip ] || fail "ancestor rev: $(cat "$(pin_of "$o" "$r2")")"
ok 'ancestor of the default tip is ancestor-of-tip'

# 3. The author names an unprotected branch: on it, but unverified.
inline "$rs" side | put Cargo.toml
o="$(evidence "$b" "$(snap side)")"; p="$(pin_of "$o" "$rs")"
[ "$(field "$p" status)" = on-unprotected-branch ] && [ "$(field "$p" verified)" = false ] \
  && [ "$(field "$p" checked_branch)" = side ] && [ "$(field "$p" checked_branch_author_supplied)" = true ] \
  && [ "$(field "$p" checked_branch_kind)" = unprotected ] || fail "unprotected named branch: $(cat "$p")"
ok 'a rev on an unprotected branch the change names is on-unprotected-branch'

# 4. A release branch the author names counts only when the forge reports it protected.
inline "$rr" release/v1 | put Cargo.toml
h="$(snap rel)"
o="$(evidence "$b" "$h")"; p="$(pin_of "$o" "$rr")"
[ "$(field "$p" status)" = on-unprotected-branch ] || fail "unprotected release branch: $(cat "$p")"
stub_release_protected=true
o="$(evidence "$b" "$h")"; p="$(pin_of "$o" "$rr")"
[ "$(field "$p" status)" = merged-tip ] && [ "$(field "$p" checked_branch)" = release/v1 ] \
  && [ "$(field "$p" checked_branch_kind)" = protected ] && [ "$(field "$p" checked_branch_author_supplied)" = true ] \
  || fail "protected release branch: $(cat "$p")"
stub_release_protected=false
ok 'a protected release branch the change names verifies; the same branch unprotected does not'

# 5. A rev on no checked branch, and a rev the forge does not have (no pin.json, no tip).
git -C "$t/forge/git/acme/core.git" update-ref refs/heads/hidden "$rs"
git -C "$t/forge/git/acme/core.git" update-ref -d refs/heads/side
inline "$rs" | put Cargo.toml
o="$(evidence "$b" "$(snap noton)")"
[ "$(field "$(pin_of "$o" "$rs")" status)" = NOT-ON-BRANCH ] || fail "rev on no checked branch: $(cat "$(pin_of "$o" "$rs")")"
git -C "$t/forge/git/acme/core.git" update-ref refs/heads/side "$rs"
bogus="$(printf 'f%.0s' {1..40})"; inline "$bogus" main | put Cargo.toml
o="$(evidence "$b" "$(snap bogus)")"
grep -q "${bogus:0:12}: rev-not-on-forge" "$o/upstream/SUMMARY.txt" || fail "unknown rev reported: $(cat "$o/upstream/SUMMARY.txt")"
[ ! -e "$(pin_of "$o" "$bogus")" ] || fail "an unresolved rev wrote pin.json"
! grep -rq "$r3" "$o/upstream" || fail "an unresolved rev leaked a branch tip: $(grep -r "$r3" "$o/upstream")"
ok 'rev on no checked branch is NOT-ON-BRANCH; an unresolved rev writes no pin.json and no tip'

# 6. A brand-new pin is not fetched.
dep new; printf '[package]\nname = "dep"\n' | put Cargo.toml; b="$(snap base)"
printf '[package]\nname = "dep"\n\n[dependencies]\nacme-other = { git = "https://forge.test/git/acme/secret.git", rev = "%s" }\n' "$r3" | put Cargo.toml
o="$(evidence "$b" "$(snap new)")"
grep -q "acme/secret ${r3:0:12}: new-pin-unverified" "$o/upstream/SUMMARY.txt" || fail "new pin: $(cat "$o/upstream/SUMMARY.txt")"
[ ! -s "$t/api.log" ] && [ ! -e "$state/cache/upstream/acme@secret.git" ] && [ "$(find "$o/upstream" -mindepth 1 ! -name SUMMARY.txt | wc -l)" = 0 ] \
  || fail "a new pin was fetched: $(cat "$t/api.log")"
ok 'a brand-new pin is new-pin-unverified and nothing is fetched'

# 7. A foreign host is not fetched, even when it was already pinned at the base.
dep foreign
printf '[dependencies]\nx = { git = "https://evil.example/git/acme/core.git", rev = "%s" }\n' "$r1" | put Cargo.toml; b="$(snap base)"
printf '[dependencies]\nx = { git = "https://evil.example/git/acme/core.git", rev = "%s" }\n' "$r3" | put Cargo.toml
o="$(evidence "$b" "$(snap evil)")"
grep -q "https://evil.example/git/acme/core ${r3:0:12}: unmapped-host" "$o/upstream/SUMMARY.txt" || fail "foreign host: $(cat "$o/upstream/SUMMARY.txt")"
[ ! -s "$t/api.log" ] && [ "$(find "$o/upstream" -mindepth 1 ! -name SUMMARY.txt | wc -l)" = 0 ] || fail "a foreign host was fetched"
ok 'a foreign host is unmapped-host and nothing is fetched'

# 8. A GitHub mirror source maps to the forge only through a mapping the base carries.
dep mirror
put .cargo/hosted-gitconfig <<'EOF'
[credential]
	helper =
[url "https://forge.test/git/acme/core.git"]
	insteadOf = https://github.com/mirror/core.git
EOF
lock() { printf '[[package]]\nname = "acme-core"\nversion = "1.0.0"\nsource = "git+https://github.com/mirror/%s.git?tag=t-1#%s"\n' "$1" "$2"; }
{ lock core "$r1"; lock unmapped "$r1"; } | put Cargo.lock; b="$(snap base)"
{ lock core "$r3"; lock unmapped "$r3"; } | put Cargo.lock
printf '[url "https://forge.test/git/acme/core.git"]\n\tinsteadOf = https://github.com/mirror/unmapped.git\n' >>"$D/.cargo/hosted-gitconfig"
h="$(snap mirror)"
rows="$(upstream_pins "$D/.git" "$b" "$h" acme | tr '\037' '\t')"
grep -qx "$(printf 'fetch\tacme/core\t%s\t%s\t\tacme-core\thttps://github.com/mirror/core' "$r1" "$r3")" <<<"$rows" || fail "mirror mapping: $rows"
grep -q "^unmapped-host	.*github.com/mirror/unmapped" <<<"$rows" || fail "a mapping added by the change itself was used: $rows"
o="$(evidence "$b" "$h")"
[ "$(field "$(pin_of "$o" "$r3")" status)" = merged-tip ] || fail "mapped mirror evidence"
ok 'a GitHub mirror source maps through the base mapping; an unmapped or change-added mapping is unmapped-host'

# 9. Real pin formats: the TSV support ref, table-form dependencies, rev= lock sources, package.
dep formats
printf '# repository|immutable tag|commit|hosted support ref\ncore|tag-a|%s|refs/heads/release/v1\n' "$r1" | put .cargo/hosted-pin-refs.tsv
table() { printf '[workspace.dependencies.acme-core]\ngit = "https://forge.test/git/acme/core.git"\nrev = "%s"\n\n[dependencies]\nfeat-core = { git = "https://forge.test/git/acme/core.git", rev = "%s", package = "acme-core" }\n' "$1" "$1"; }
table "$r1" | put Cargo.toml; b="$(snap base)"
printf '# repository|immutable tag|commit|hosted support ref\ncore|tag-b|%s|refs/heads/release/v1\n' "$rr" | put .cargo/hosted-pin-refs.tsv
table "$r3" | put Cargo.toml; h="$(snap fmt)"
rows="$(upstream_pins "$D/.git" "$b" "$h" acme | tr '\037' '\t')"
grep -qx "$(printf 'fetch\tacme/core\t%s\t%s\trelease/v1\t\ttsv:core' "$r1" "$rr")" <<<"$rows" || fail "tsv support ref: $rows"
grep -qx "$(printf 'fetch\tacme/core\t%s\t%s\t\tacme-core\thttps://forge.test/git/acme/core' "$r1" "$r3")" <<<"$rows" || fail "table and package form: $rows"
[ "$(printf '%s\n' "$rows" | grep -c .)" = 2 ] || fail "table and inline pins of one repo and rev are one row: $rows"
stub_release_protected=true
o="$(evidence "$b" "$h")"
[ "$(field "$(pin_of "$o" "$rr")" checked_branch)" = release/v1 ] && [ "$(field "$(pin_of "$o" "$rr")" status)" = merged-tip ] || fail "tsv evidence: $(cat "$(pin_of "$o" "$rr")")"
stub_release_protected=false
ok 'TSV support ref, table form, package rename and rev= lock source are read'

# 10. Total size is capped across pins, and every cut is noted.
git init -q -b main "$t/big"; head -c 200000 /dev/urandom | base64 >"$t/big/a"; printf '[package]\nname = "big"\n' >"$t/big/Cargo.toml"
git -C "$t/big" add -A; git -C "$t/big" -c user.name=t -c user.email=t@t commit -qm a; k1="$(git -C "$t/big" rev-parse HEAD)"
head -c 200000 /dev/urandom | base64 >"$t/big/a"; git -C "$t/big" -c user.name=t -c user.email=t@t commit -qam b; k2="$(git -C "$t/big" rev-parse HEAD)"
git clone -q --bare "$t/big" "$t/forge/git/acme/big.git"
dep size
two() { printf '[dependencies]\nacme-core = { git = "https://forge.test/git/acme/core.git", rev = "%s" }\nbig = { git = "https://forge.test/git/acme/big.git", rev = "%s" }\n' "$1" "$2"; }
two "$r1" "$k1" | put Cargo.toml; b="$(snap base)"; two "$r3" "$k2" | put Cargo.toml
o="$(budget=6000 evidence "$b" "$(snap size)")"
used="$(cat "$o"/upstream/*/log.txt "$o"/upstream/*/diff.patch "$o"/upstream/*/pulls.json 2>/dev/null | wc -c)"
[ "$used" -le 6000 ] || fail "upstream evidence is $used bytes over a 6000-byte budget"
[ "$(jq -r .diff.truncated "$o/upstream/acme@big-${k2:0:12}/pin.json")" = true ] || fail "the cut is in pin.json"
grep -q "big ${k2:0:12}: merged-tip.*truncated" "$o/upstream/SUMMARY.txt" && grep -q 'diff.patch cut' "$o/upstream/acme@big-${k2:0:12}/note.txt" \
  || fail "the cut is in SUMMARY.txt and note.txt: $(cat "$o/upstream/SUMMARY.txt")"
ok 'upstream evidence is capped in total across pins and each cut is noted'

# 11. A failed branch fetch never leaves an earlier run's tip (packed) to compare against.
D="$t/dep-fwd"; b="$(git -C "$D" rev-list --max-parents=0 HEAD)"
g="$state/cache/upstream/acme@core.git"
git -C "$g" update-ref refs/up/b0 "$r3"; git -C "$g" update-ref refs/up/b1 "$r3"; git -C "$g" pack-refs --all
stub_default=vanished
inline "$r2" | put Cargo.toml; git -C "$D" checkout -q "$b" -- Cargo.lock
o="$(evidence "$b" "$(snap stale)")"; p="$(pin_of "$o" "$r2")"
[ "$(field "$p" status)" = ancestor-of-tip ] && [ "$(field "$p" checked_branch)" = main ] && [ "$(field "$p" checked_branch_kind)" = protected ] \
  || fail "stale tip: $(cat "$p")"
jq -e '.notes | map(select(test("branch vanished could not be fetched"))) | length == 1' "$p" >/dev/null || fail "failed fetch noted: $(cat "$p")"
! git -C "$g" rev-parse -q --verify refs/up/b0 >/dev/null || [ "$(git -C "$g" rev-parse refs/up/b0)" != "$r3" ] || fail "stale ref b0 survived"
stub_default=main
ok 'a failed branch fetch deletes the earlier tip instead of reusing it'

# 12. Truncation of commits and pull request pages, and a pin moving backwards, are noted.
inline "$r1" | put Cargo.toml; b2="$(snap down-base)"
git -C "$D" checkout -q "$b" -- Cargo.toml; inline "$r3" | put Cargo.toml; up3="$(snap up3)"
inline "$r1" | put Cargo.toml
pulls_more=true upstream_max_commits=1 upstream_max_pull_pages=2
o="$(evidence "$up3" "$(snap down)")"; p="$(pin_of "$o" "$r1")"
pulls_more=false upstream_max_commits=50 upstream_max_pull_pages=10
[ "$(field "$p" direction)" = backward ] && grep -q BACKWARDS "$(dirname "$p")/note.txt" || fail "backward pin: $(cat "$p")"
[ "$(field "$p" commits.truncated)" = true ] && grep -q 'newest 1 of 2 commits' "$(dirname "$p")/note.txt" || fail "commit cut: $(cat "$p")"
[ "$(field "$p" pulls.truncated)" = true ] && [ "$(field "$p" pulls.pages_read)" = 2 ] && grep -q 'newest 2 pages' "$(dirname "$p")/note.txt" \
  || fail "pull page cut: $(cat "$p")"
grep -q "${r1:0:12}: .*truncated" "$o/upstream/SUMMARY.txt" || fail "summary notes the cut"
ok 'a backwards pin, a cut commit list and unread pull request pages are noted'

# 13. No moved pin, no upstream/.
echo x | put readme; o="$t/plain"; mkdir -p "$o"
upstream_evidence "$D/.git" "$b2" "$(snap doc)" "$o" acme 100000
[ ! -e "$o/upstream" ] || fail "no pin moved but upstream/ exists"
ok 'a change that moves no pin gets no upstream/'

# 14. Credentials: the ambient helper and netrc are never used; only the reviewer's credential is.
# Asked for a credential for the forge, plain git reaches the ambient helper (so the trap is live);
# the configuration every upstream fetch runs under answers with the reviewer's alone.
printf 'protocol=https\nhost=forge.test\n\n' | git credential fill >/dev/null 2>&1 || true
[ -s "$t/ambient-called" ] || fail "the ambient credential helper is not live, so this case proves nothing"
rm -f "$t/ambient-called"
cred="$(printf 'protocol=https\nhost=forge.test\n\n' | upstream_git credential fill 2>&1)" || fail "credential fill: $cred"
[ ! -e "$t/ambient-called" ] || fail "an upstream fetch's git invoked the ambient credential helper"
grep -qx 'password=dummytoken' <<<"$cred" && grep -qx 'username=reviewer' <<<"$cred" || fail "the reviewer credential is not the one presented: $cred"
uphome="$(upstream_git -c 'alias.home=!printf %s "$HOME"' home)"
[ "$uphome" != "$HOME" ] && [ ! -e "$uphome/.netrc" ] || fail "an upstream fetch can read the ambient netrc"
[ -z "$(upstream_git config --global --list 2>/dev/null)" ] || fail "an upstream fetch reads the global git configuration"
# And through a real fetch: the whole fwd evidence run above left no call either.
D="$t/dep-fwd"; b="$(git -C "$D" rev-list --max-parents=0 HEAD)"; inline "$r3" | put Cargo.toml
o="$(evidence "$b" "$(snap cred)")"
[ "$(field "$(pin_of "$o" "$r3")" status)" = merged-tip ] && [ ! -e "$t/ambient-called" ] || fail "fetch under the trap"
ok 'upstream fetches never invoke the ambient credential helper or netrc'

echo "UPSTREAM EVIDENCE PASS"
