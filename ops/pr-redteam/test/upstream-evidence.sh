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
    upstream_capped upstream_drop_refs upstream_pull_approved upstream_replay_tree upstream_pin_evidence upstream_evidence; do
  eval "$(sed -n "/^$f() {/,/^}/p" "$script")"
  declare -F "$f" >/dev/null || fail "$f not found in pr-redteam"
done
upstream_max_pins=6 upstream_max_bytes=100000 upstream_max_commits=50 upstream_fetch_timeout=20
upstream_max_branches=8 upstream_max_pull_pages=10 upstream_min_share=1024
state="$t/state"; me=reviewer
# The stand-in forge is a directory served over file://; the real upstream_remote builds
# $base/git/<owner>/<name>.git from it. Manifests name the forge by its host, forge.test.
base="file://$t/forge"; forge_host=forge.test; forge_aliases=""
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

# The forge API, answering exactly the two repository reads and the pull request listing the
# evidence code makes, in the shapes the live forge returns (checked against it): the repository
# read carries default_branch; /refs is an array of {name, sha, kind, protected}. Any other
# repository path is recorded and fails the suite at the end.
stub_default=main stub_release_protected=false stub_main_protected=true pulls_more=false stub_pulls='{"items":[]}'
stub_review=APPROVED stub_review_author="" # (empty: this reviewer) what /pulls/<n> reports for each pull request's head
upstream_ref_rows() { # bare-repo: one {name, sha, kind:"branch", protected:false} per branch
  git -C "$1" for-each-ref --format='%(refname:strip=2) %(objectname)' refs/heads/ |
    jq -Rc 'split(" ") | {name: .[0], sha: .[1], kind: "branch", protected: false}' | jq -sc .
}
api() {
  echo "$2" >>"$t/api.log"; code=200
  local r
  case "$2" in
    /api/v1/repos/acme%2Fcore|/api/v1/repos/acme%2Fbig)
      r="${2#/api/v1/repos/}"; r="${r/\%2F//}"
      body="$(jq -nc --arg o "${r%%/*}" --arg n "${r#*/}" --arg d "$stub_default" '{
        api_url: ("https://forge.test/api/v1/repos/" + $o + "/" + $n), archived: false,
        clone_http_url: ("/git/" + $o + "/" + $n + ".git"), clone_ssh_url: null, default_branch: $d,
        id: {host: "forge", name: $n, owner: $o}, open_pull_requests: 1, visibility: "private"}')" ;;
    /api/v1/repos/acme%2Fcore/refs|/api/v1/repos/acme%2Fbig/refs)
      r="${2#/api/v1/repos/}"; r="${r%/refs}"; r="${r/\%2F//}"
      body="$(upstream_ref_rows "$t/forge/git/$r.git" | jq -c --argjson rp "$stub_release_protected" --argjson mp "$stub_main_protected" '
        map(if .name == "main" then .protected = $mp elif .name == "release/v1" then .protected = $rp else . end)
        + [{name: "v1", sha: "0000000000000000000000000000000000000000", kind: "tag", protected: false}]')" ;;
    /api/v1/repos/acme%2Fcore/pulls\?state=all\&per_page=100\&page=[0-9]*|/api/v1/repos/acme%2Fbig/pulls\?state=all\&per_page=100\&page=[0-9]*)
      body="$(jq -c --argjson more "$pulls_more" --argjson p "${2##*page=}" \
        '. + {total: (.items | length), page: {limit: 100, page: $p, total: (.items | length), has_more: $more}}' <<<"$stub_pulls")" ;;
    # One pull request's detail: its reviews, in the live shape ({author, state, head_sha, effective,
    # stale}); the head is the one the listing gives that number.
    /api/v1/repos/acme%2Fcore/pulls/[0-9]*|/api/v1/repos/acme%2Fbig/pulls/[0-9]*)
      body="$(jq -c --argjson n "${2##*/}" --arg s "$stub_review" --arg a "${stub_review_author:-${me:-pragent}}" '
        (.items[] | select(.number == $n) | .head_sha) as $h
        | {summary: {author: "dev"}, reviews: [{author: $a, state: $s, head_sha: $h, effective: true, stale: false,
            body_markdown: "**Red team: approved.**", id: "r1", submitted_at: "2026-10-24T00:00:00Z"}]}' <<<"$stub_pulls")" ;;
    # The GitHub-shaped closed listing, which carries each landing's merge_commit_sha: these stubs
    # land every merged pull request at its own head (test/queue-landing.sh covers replays).
    /api/v3/repos/acme/core/pulls\?state=closed\&per_page=100\&page=[0-9]*|/api/v3/repos/acme/big/pulls\?state=closed\&per_page=100\&page=[0-9]*)
      body="$(jq -c '[.items[] | select(.state == "merged")
        | {number, title, merged_at: "2026-10-24T00:00:00Z", merge_commit_sha: .head_sha,
           head: {ref: .head_ref, sha: .head_sha}, base: {ref: .base_ref, sha: (.base_sha // null)}}]' <<<"$stub_pulls")"
      [ "${2##*page=}" = 1 ] || body='[]' ;;
    # A repository the forge does not have: the one read a lock entry makes before fetching anything.
    /api/v1/repos/acme%2Fghost) code=404; body='{"error":{"code":"not_found"}}' ;;
    *) echo "$2" >>"$t/api.unexpected"; code=404; body='{"error":{"code":"not_found"}}' ;;
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

# 1b. Already reviewed upstream: every commit of r1..r3 lies between the base and head of a pull
# request merged into main (which the forge protects), so the diff is not fetched; anything less --
# including a commit that is only an ANCESTOR of a merged pull request -- keeps it.
hb="$(git -C "$D" rev-parse HEAD)"
merged_into() { # base_ref state head:base... -> pulls stub
  local b=$1 s=$2; shift 2
  printf '{"items":[%s]}' "$(n=0; for hp in "$@"; do n=$((n + 1)); printf '{"number":%s,"state":"%s","title":"x","head_ref":"f","base_ref":"%s","head_sha":"%s","base_sha":"%s"},' "$n" "$s" "$b" "${hp%%:*}" "${hp##*:}"; done | sed 's/,$//')"
}
stub_pulls="$(merged_into main merged "$r2:$r1" "$r3:$r2")"
o="$(evidence "$b" "$hb")"; p="$(pin_of "$o" "$r3")"; dir="$(dirname "$p")"
[ "$(field "$p" already_reviewed_upstream)" = true ] && [ "$(jq -r .diff.fetched "$p")" = false ] && [ ! -e "$dir/diff.patch" ] \
  && grep -q 'core/src/lib.rs' "$dir/diffstat.txt" && grep -q '^already reviewed upstream: each of the 2 commits' "$dir/note.txt" \
  && grep -q "${r3:0:12}: merged-tip.*already reviewed upstream: diff not fetched" "$o/upstream/SUMMARY.txt" \
  && [ "$(jq -c '[.approved_pulls[].number]' "$p")" = '[1,2]' ] \
  && [ "$(jq -c --arg a "$r2" --arg b "$r3" '[.commit_pulls[$a], .commit_pulls[$b]]' "$p")" = '[1,2]' ] \
  || fail "fully reviewed upstream range: $(cat "$p"; ls "$dir")"
stub_pulls="$(merged_into main merged "$r3:$r1")"   # one pull request carrying both commits
o="$(evidence "$b" "$hb")"; [ "$(field "$(pin_of "$o" "$r3")" already_reviewed_upstream)" = true ] || fail "one PR with both commits"
for case in "main merged $r3:$r2" "release/v1 merged $r3:$r1" "main open $r3:$r1" "main merged $r2:$r1"; do
  read -r cb cs ch <<<"$case"; stub_pulls="$(merged_into "$cb" "$cs" "$ch")"
  o="$(evidence "$b" "$hb")"; p="$(pin_of "$o" "$r3")"
  [ "$(field "$p" already_reviewed_upstream)" = false ] && [ "$(jq -r .diff.fetched "$p")" = true ] && grep -q '^+three' "$(dirname "$p")/diff.patch" \
    || fail "a commit outside every PR merged into the checked branch ($case) keeps the diff: $(cat "$p")"
done
grep -q "of the range's commits are in no pull request this reviewer approved" "$(dirname "$p")/note.txt" || fail "the unattributed count is noted"
# Every commit covered, but the approval is someone else's, a hold, or main is not protected: diff.
stub_pulls="$(merged_into main merged "$r3:$r1")"
for miss in "stub_review_author=someone" "stub_review=CHANGES_REQUESTED" "stub_main_protected=false"; do
  ( eval "$miss"; o="$(evidence "$b" "$hb")"; p="$(pin_of "$o" "$r3")"
    [ "$(field "$p" already_reviewed_upstream)" = false ] && [ "$(jq -r .diff.fetched "$p")" = true ] \
      || fail "no approval by this reviewer at the head, or an unprotected branch ($miss), keeps the diff: $(cat "$p")" ) || exit 1
done
stub_pulls="$(merged_into main merged "$r3:$r1")"; pulls_more=true
o="$(evidence "$b" "$hb")"; [ "$(field "$(pin_of "$o" "$r3")" already_reviewed_upstream)" = false ] || fail "unread pull request pages keep the diff"
pulls_more=false
inline "$r1" | put Cargo.toml; git -C "$D" checkout -q "$b" -- Cargo.lock; hback="$(snap back)"
o="$(evidence "$hb" "$hback")"; p="$(pin_of "$o" "$r1")"
[ "$(field "$p" already_reviewed_upstream)" = false ] && [ "$(jq -r .diff.fetched "$p")" = true ] || fail "a backwards pin keeps its diff: $(cat "$p")"
git -C "$D" reset -q --hard "$hb"
stub_pulls="{\"items\":[{\"number\":9,\"state\":\"merged\",\"title\":\"two\",\"head_ref\":\"feat\",\"base_ref\":\"main\",\"head_sha\":\"$r2\"}]}"
ok 'a forward pin whose every commit is in a PR this reviewer approved at its head and merged into a protected branch skips the diff; anything less keeps it'

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
git -C "$t/forge/git/acme/core.git" update-ref refs/heads/side "$r1"
inline "$rs" side | put Cargo.toml
o="$(evidence "$b" "$(snap noton-named)")"; p="$(pin_of "$o" "$rs")"
[ "$(field "$p" status)" = NOT-ON-BRANCH ] && [ "$(field "$p" checked_branch)" = "" ] && [ "$(field "$p" checked_branch_tip)" = "" ] \
  || fail "NOT-ON-BRANCH names no checked branch: $(cat "$p")"
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

# 7b. A configured forge alias host is the forge's own /git route; an unlisted host stays unmapped.
dep alias
al() { printf '[dependencies]\nx = { git = "https://%s/git/acme/core.git", rev = "%s" }\n' "$1" "$2"; }
al git.alias.test "$r1" | put Cargo.toml; b="$(snap base)"
al git.alias.test "$r3" | put Cargo.toml; h="$(snap alias)"
forge_aliases=" git.alias.test"
rows="$(upstream_pins "$D/.git" "$b" "$h" acme | tr '\037' '\t')"
grep -qx "$(printf 'fetch\tacme/core\t%s\t%s\t\tx\thttps://git.alias.test/git/acme/core' "$r1" "$r3")" <<<"$rows" || fail "alias host: $rows"
o="$(evidence "$b" "$h")"
[ "$(field "$(pin_of "$o" "$r3")" status)" = merged-tip ] || fail "alias evidence: $(cat "$o/upstream/SUMMARY.txt")"
[ "$(field "$(pin_of "$o" "$r3")" source_url)" = https://git.alias.test/git/acme/core ] || fail "alias source not in pin.json"
grep -q "acme/core ${r3:0:12}: merged-tip.*\[source https://git.alias.test/git/acme/core: forge alias host git.alias.test (REDTEAM_FORGE_ALIASES); verified and fetched on forge.test only\]" \
  "$o/upstream/SUMMARY.txt" || fail "alias route not on the summary row: $(cat "$o/upstream/SUMMARY.txt")"
forge_aliases=""
rows="$(upstream_pins "$D/.git" "$b" "$h" acme | tr '\037' '\t')"
grep -q "^unmapped-host	" <<<"$rows" || fail "unconfigured alias was mapped: $rows"
forge_aliases=" git.alias.test"
al evil.example "$r1" | put Cargo.toml; b="$(snap base2)"; al evil.example "$r3" | put Cargo.toml; h="$(snap evil2)"
rows="$(upstream_pins "$D/.git" "$b" "$h" acme | tr '\037' '\t')"
grep -q "^unmapped-host	" <<<"$rows" || fail "hostile host mapped with aliases set: $rows"
forge_aliases=""
ok 'a configured forge alias host maps to the forge route; unlisted hosts stay unmapped-host'

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

# 12b. A budget too small to hold anything fetches nothing and writes no negative byte count.
D="$t/dep-size"; b="$(git -C "$D" rev-list --max-parents=0 HEAD)"
three() { printf '[dependencies]\nacme-core = { git = "https://forge.test/git/acme/core.git", rev = "%s" }\nbig = { git = "https://forge.test/git/acme/big.git", rev = "%s" }\nbig2 = { git = "https://forge.test/git/acme/core.git", rev = "%s", package = "acme-core" }\n' "$1" "$2" "$3"; }
three "$r1" "$k1" "$r1" | put Cargo.toml; b3="$(snap three-base)"
three "$r3" "$k2" "$r2" | put Cargo.toml
o="$(budget=1 evidence "$b3" "$(snap three)")"
[ "$(grep -cE 'not fetched: its share of the upstream evidence budget \([01] bytes\) is too small' "$o/upstream/SUMMARY.txt")" = 3 ] \
  || fail "a 1-byte budget across three pins: $(cat "$o/upstream/SUMMARY.txt")"
[ "$(find "$o/upstream" -mindepth 1 ! -name SUMMARY.txt | wc -l)" = 0 ] || fail "a 1-byte budget fetched something"
! grep -rqE -- '-[0-9]+ bytes|"bytes": -' "$o/upstream" || fail "a negative byte count was written"
o="$(budget=5000 evidence "$b3" "$(snap three-b)")"
! grep -rqE -- 'at -[0-9]|"bytes": -' "$o/upstream" || fail "a negative byte count was written: $(cat "$o"/upstream/*/note.txt)"
ok 'a budget too small for a pin fetches nothing and no byte count goes negative'

# 12c. Parallel reviews of the same upstream pin share the cache, never a tip. Each pair names a
# different branch: the default-only review must not read the unprotected branch's tip as main.
D="$t/dep-fwd"; b="$(git -C "$D" rev-list --max-parents=0 HEAD)"
inline "$rs" | put Cargo.toml; hA="$(snap par-a)"
inline "$rs" side | put Cargo.toml; hB="$(snap par-b)"
for round in 1 2 3 4 5; do
  oa="$(mktemp -d "$t/par-a-XXXXXX")"; ob="$(mktemp -d "$t/par-b-XXXXXX")"
  upstream_evidence "$D/.git" "$b" "$hA" "$oa" acme 100000 & pa=$!
  upstream_evidence "$D/.git" "$b" "$hB" "$ob" acme 100000 & pb=$!
  wait "$pa"; wait "$pb"
  [ "$(field "$(pin_of "$oa" "$rs")" status)" = NOT-ON-BRANCH ] && [ "$(field "$(pin_of "$oa" "$rs")" verified)" = false ] \
    || fail "round $round: a parallel review read another's tip: $(cat "$(pin_of "$oa" "$rs")")"
  [ "$(field "$(pin_of "$ob" "$rs")" status)" = on-unprotected-branch ] && [ "$(field "$(pin_of "$ob" "$rs")" checked_branch)" = side ] \
    || fail "round $round: the named-branch review: $(cat "$(pin_of "$ob" "$rs")")"
done
[ -z "$(git -C "$state/cache/upstream/acme@core.git" for-each-ref --format='%(refname)' refs/up/ | grep -vx 'refs/up/b[01]')" ] \
  || fail "a review left its refs behind"
ok 'parallel reviews of one upstream never see each other'"'"'s tips and leave no refs'

# 12d. Release lock entries: a `[[repo]]` table of a root *.lock.toml names a repository of the
# dependent's owner, a commit and a tag. The github/jeryu URL fields are never fetch targets.
tagup() { git -C "$t/forge/git/acme/core.git" -c user.name=t -c user.email=t@t tag "$@"; }
tagup -a core-v1 -m v1 "$r1"; tagup -a core-v3 -m v3 "$r3"; tagup core-v3-lw "$r3"; tagup -a core-v2 -m v2 "$r2"
tagup -a core-side -m side "$rs"
entry() { # repo tag commit dist
  printf '\n[[repo]]\nrepo = "%s"\ntag = "%s"\ncommit = "%s"\nweb_dist_sha256 = "%s"\ngithub = "https://github.example/evil/%s.git"\njeryu = "http://mirror.invalid/git/evil/%s.git"\nrequired_check = "%s/required"\n' \
    "$1" "$2" "$3" "$4" "$1" "$1" "$1"
}
lockfile() { printf 'schema_version = "1.0.0"\nfamily = "acme"\n\n[nested.engine]\nengine_commit = "%s"\n' "$r1"; }
dist1="$(printf 'a%.0s' {1..64})" dist3="$(printf 'b%.0s' {1..64})"
dep lock; { lockfile; entry core core-v1 "$r1" "$dist1"; entry ghost ghost-v1 "$r1" "$dist1"; } | put acme.lock.toml; b="$(snap base)"
lock_case() { # name: the lock at the head, on stdin -> review dir
  put acme.lock.toml; evidence "$b" "$(snap "$1")"
}
nofetch() { ! grep -q evil "$t/api.log" && ! grep -rq 'evil\|mirror.invalid' "$state/cache/upstream" 2>/dev/null; }

o="$( { lockfile; entry core core-v3 "$r3" "$dist3"; entry ghost ghost-v1 "$r1" "$dist1"; } | lock_case lock-bump)"
p="$(pin_of "$o" "$r3")"; dir="$(dirname "$p")"
[ "$(field "$p" status)" = merged-tip ] && [ "$(field "$p" verified)" = true ] && [ "$(field "$p" lock_entry)" = true ] \
  && [ "$(field "$p" checked_branch)" = main ] && [ "$(field "$p" old_rev)" = "$r1" ] || fail "lock bump: $(cat "$p")"
[ "$(field "$p" tag)" = core-v3 ] && [ "$(field "$p" old_tag)" = core-v1 ] && [ "$(field "$p" tag_resolves_to)" = "$r3" ] \
  && [ "$(field "$p" tag_matches_commit)" = true ] && [ "$(field "$p" tag_annotated)" = true ] || fail "lock tag: $(cat "$p")"
jq -e --arg d3 "$dist3" --arg d1 "$dist1" '.locked_fields | (map(.name) | sort) == ["required_check", "web_dist_sha256"]
  and (map(select(.name == "web_dist_sha256"))[0] | .value == $d3 and .base_value == $d1 and .changed == true
    and .provenance == "author-measured, not reproduced by the reviewer")' "$p" >/dev/null || fail "locked fields: $(jq -c .locked_fields "$p")"
grep -q "commit $r2" "$dir/log.txt" && grep -q '^+three' "$dir/diff.patch" && grep -q 'core/src/lib.rs' "$dir/diffstat.txt" \
  && [ "$(jq -r '.[0].number' "$dir/pulls.json")" = 9 ] || fail "lock log, diff, diff stat and pulls"
grep -q "acme/core ${r3:0:12}: merged-tip (branch main, default); tag core-v3 peels to it (annotated)" "$o/upstream/SUMMARY.txt" \
  || fail "lock summary row: $(cat "$o/upstream/SUMMARY.txt")"
grep -q 'tag-mismatch' "$o/upstream/SUMMARY.txt" && [ "$(grep -c "${r1:0:12}" "$o/upstream/SUMMARY.txt")" = 0 ] \
  || fail "the summary explains lock statuses and lists only the moved entry: $(cat "$o/upstream/SUMMARY.txt")"
nofetch || fail "a lock URL field was used: $(cat "$t/api.log")"
ok 'a lock bump onto the default tip, with a tag that peels to it, is verified; locked fields are author-measured'

o="$( { lockfile; entry core core-v2 "$r3" "$dist3"; entry ghost ghost-v1 "$r1" "$dist1"; } | lock_case lock-mismatch)"
p="$(pin_of "$o" "$r3")"
[ "$(field "$p" status)" = tag-mismatch ] && [ "$(field "$p" verified)" = false ] && [ "$(field "$p" branch_status)" = merged-tip ] \
  && [ "$(field "$p" tag_resolves_to)" = "$r2" ] && [ "$(field "$p" tag_matches_commit)" = false ] || fail "tag mismatch: $(cat "$p")"
grep -q "acme/core ${r3:0:12}: tag-mismatch (tag core-v2 peels to ${r2:0:12}, not the locked commit; the commit itself: merged-tip, branch main, default)" "$o/upstream/SUMMARY.txt" \
  || fail "mismatch summary: $(cat "$o/upstream/SUMMARY.txt")"
o="$( { lockfile; entry core core-v9 "$r3" "$dist3"; entry ghost ghost-v1 "$r1" "$dist1"; } | lock_case lock-notag)"
p="$(pin_of "$o" "$r3")"
[ "$(field "$p" status)" = tag-mismatch ] && [ "$(field "$p" tag_resolves_to)" = null ] && grep -q 'core-v9 not found on the forge' "$o/upstream/SUMMARY.txt" \
  || fail "missing tag: $(cat "$p")"
ok 'a tag that peels to another commit, or is missing from the forge, is tag-mismatch and unverified'

o="$( { lockfile; entry core core-v3-lw "$r3" "$dist3"; entry ghost ghost-v1 "$r1" "$dist1"; } | lock_case lock-lw)"
p="$(pin_of "$o" "$r3")"
[ "$(field "$p" status)" = merged-tip ] && [ "$(field "$p" tag_matches_commit)" = true ] && [ "$(field "$p" tag_annotated)" = false ] \
  && [ "$(field "$p" tag_object_type)" = commit ] && jq -e '.notes | map(select(test("lightweight tag"))) | length == 1' "$p" >/dev/null \
  && grep -q "tag core-v3-lw peels to it (lightweight)" "$o/upstream/SUMMARY.txt" || fail "lightweight tag: $(cat "$p")"
ok 'a lightweight tag that peels to the commit verifies and is recorded as not annotated'

o="$( { lockfile; entry core core-v1 "$r1" "$dist1"; entry ghost ghost-v1 "$r1" "$dist1"; entry secret secret-v1 "$r3" "$dist3"; } | lock_case lock-new)"
grep -q "acme/secret ${r3:0:12}: new-pin-unverified" "$o/upstream/SUMMARY.txt" || fail "new lock entry: $(cat "$o/upstream/SUMMARY.txt")"
[ ! -s "$t/api.log" ] && [ ! -e "$state/cache/upstream/acme@secret.git" ] && [ "$(find "$o/upstream" -mindepth 1 ! -name SUMMARY.txt | wc -l)" = 0 ] \
  || fail "a new lock entry was fetched: $(cat "$t/api.log")"
ok 'a lock entry new at the head is new-pin-unverified and nothing is fetched'

o="$( { lockfile; entry core core-v1 "$r1" "$dist1"; entry ghost ghost-v3 "$r3" "$dist3"; } | lock_case lock-ghost)"
grep -q "acme/ghost ${r3:0:12}: repo-not-on-forge" "$o/upstream/SUMMARY.txt" || fail "ghost repository: $(cat "$o/upstream/SUMMARY.txt")"
[ "$(cat "$t/api.log")" = '/api/v1/repos/acme%2Fghost' ] && [ ! -e "$state/cache/upstream/acme@ghost.git" ] \
  && [ "$(find "$o/upstream" -mindepth 1 ! -name SUMMARY.txt | wc -l)" = 0 ] || fail "a repository the forge lacks was fetched: $(cat "$t/api.log")"
nofetch || fail "a lock URL field was used for a repository the forge lacks"
ok 'a lock entry whose repository is not on the forge is repo-not-on-forge and nothing is fetched'

o="$( { lockfile; entry core core-side "$rs" "$dist3"; entry ghost ghost-v1 "$r1" "$dist1"; } | lock_case lock-side)"
p="$(pin_of "$o" "$rs")"
[ "$(field "$p" status)" = NOT-ON-BRANCH ] && [ "$(field "$p" verified)" = false ] && [ "$(field "$p" tag_matches_commit)" = true ] \
  && [ "$(field "$p" checked_branch)" = "" ] || fail "lock commit on an unprotected branch: $(cat "$p")"
ok 'a lock commit only on an unprotected branch is unverified even when its tag peels to it'

# A lock whose [[repo]] tables name the repository with `name =` (no `repo =`), and an entry pinned
# by commit alone: it has no tag at the base or the head, so it is judged by its commit, as a git rev
# pin is. Location fields (`github_slug`, `local_path`) are neither fetch targets nor locked fields.
named() { # name commit dist [tag]
  printf '\n[[repo]]\nname = "%s"\ngithub_slug = "evil/%s"\nlocal_path = "/srv/evil/%s"\n%scommit = "%s"\nweb_dist_sha256 = "%s"\nrequired_check = "%s/required"\n' \
    "$1" "$1" "$1" "${4:+tag = \"$4\"\n}" "$2" "$3" "$1"
}
namedlock() { printf 'schema_version = "acme.split.lock/v1"\n'; }
dep named; { namedlock; named core "$r1" "$dist1"; named self PENDING_SELF "$dist1"; } | put acme-split.lock.toml; b="$(snap base)"
{ namedlock; named core "$r3" "$dist3"; named self PENDING_SELF "$dist1"; } | put acme-split.lock.toml
o="$(evidence "$b" "$(snap named-bump)")"; p="$(pin_of "$o" "$r3")"
[ "$(field "$p" status)" = merged-tip ] && [ "$(field "$p" verified)" = true ] && [ "$(field "$p" lock_entry)" = true ] \
  && [ "$(field "$p" untagged)" = true ] && [ "$(field "$p" tag_matches_commit)" = false ] && [ "$(field "$p" old_rev)" = "$r1" ] \
  || fail "untagged named lock entry: $(cat "$p")"
jq -e '.locked_fields | (map(.name) | sort) == ["required_check", "web_dist_sha256"]' "$p" >/dev/null \
  || fail "location fields recorded as locked fields: $(jq -c .locked_fields "$p")"
grep -q "acme/core ${r3:0:12}: merged-tip (branch main, default); untagged entry: judged by its commit alone" "$o/upstream/SUMMARY.txt" \
  || fail "untagged summary row: $(cat "$o/upstream/SUMMARY.txt")"
! grep -q 'acme/self' "$o/upstream/SUMMARY.txt" && ! grep -q evil "$t/api.log" || fail "a pending entry or a location field was fetched: $(cat "$t/api.log")"
ok 'a [[repo]] entry named by name = and pinned by commit alone is judged by its commit; location fields are ignored'

dep named-drop; { namedlock; named core "$r1" "$dist1" core-v1; } | put acme-split.lock.toml; b="$(snap base)"
{ namedlock; named core "$r3" "$dist3"; } | put acme-split.lock.toml
o="$(evidence "$b" "$(snap named-drop)")"; p="$(pin_of "$o" "$r3")"
[ "$(field "$p" status)" = tag-mismatch ] && [ "$(field "$p" verified)" = false ] && [ "$(field "$p" untagged)" = false ] \
  && [ "$(field "$p" branch_status)" = merged-tip ] || fail "a removed tag: $(cat "$p")"
ok 'an entry whose tag the change removes is tag-mismatch, not untagged'

# A *.lock.toml below the root is not a release lock.
mkdir -p "$D/sub"; { lockfile; entry core core-v1 "$r1" "$dist1"; } >"$D/sub/x.lock.toml"; b="$(snap sub-base)"
{ lockfile; entry core core-v3 "$r3" "$dist3"; } >"$D/sub/x.lock.toml"
o="$t/sub-lock"; mkdir -p "$o"; upstream_evidence "$D/.git" "$b" "$(snap sub)" "$o" acme 100000
[ ! -e "$o/upstream" ] || fail "a nested *.lock.toml was read as a release lock: $(cat "$o/upstream/SUMMARY.txt")"
ok 'only a *.lock.toml at the repository root is a release lock'

# 13. No moved pin, no upstream/.
dep plain; inline "$r1" | put Cargo.toml; b2="$(snap base)"
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
other="$(printf 'protocol=https\nhost=other.test\n\n' | upstream_git credential fill 2>&1 || true)"
! grep -q dummytoken <<<"$other" || fail "the reviewer credential is offered to another host"
other="$(printf 'protocol=https\nhost=forge.test.other.test\n\n' | upstream_git credential fill 2>&1 || true)"
! grep -q dummytoken <<<"$other" || fail "the reviewer credential is offered to a lookalike host"
uphome="$(upstream_git -c 'alias.home=!printf %s "$HOME"' home)"
[ "$uphome" != "$HOME" ] && [ ! -e "$uphome/.netrc" ] || fail "an upstream fetch can read the ambient netrc"
[ -z "$(upstream_git config --global --list 2>/dev/null)" ] || fail "an upstream fetch reads the global git configuration"
# And through a real fetch: the whole fwd evidence run above left no call either.
D="$t/dep-fwd"; b="$(git -C "$D" rev-list --max-parents=0 HEAD)"; inline "$r3" | put Cargo.toml
o="$(evidence "$b" "$(snap cred)")"
[ "$(field "$(pin_of "$o" "$r3")" status)" = merged-tip ] && [ ! -e "$t/ambient-called" ] || fail "fetch under the trap"
ok 'upstream fetches never invoke the ambient credential helper or netrc'

[ ! -s "$t/api.unexpected" ] || fail "the evidence code called forge paths the stub does not model: $(sort -u "$t/api.unexpected")"
ok 'every forge path called is one the live forge serves in the modelled shape'
echo "UPSTREAM EVIDENCE PASS"
