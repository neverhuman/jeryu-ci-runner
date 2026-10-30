#!/usr/bin/env bash
# The functions under test read globals set here, so SC2034 does not apply to this file.
# shellcheck disable=SC2034
# Offline: a pin whose range landed through a merge queue. The queue replays an approved head onto
# the branch tip, so the landed commits differ from the head this reviewer approved; the forge
# records each landing as the pull request's merge_commit_sha. Such a landing counts as already
# reviewed upstream only when it lines up exactly with the approved pull request, and every other
# shape (a direct push, a squash, a missing landing commit, an edited replay, an unreadable listing,
# an approval on another head) keeps the diff.
#   test/queue-landing.sh      exit 0 when every case behaves
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../pr-redteam"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
fail() { echo "not ok - $1" >&2; exit 1; }
ok() { echo "ok - $1"; }
eval "$(grep -m1 "^say() {" "$script")"
for f in upstream_manifest_pins upstream_url_map upstream_pins upstream_tag upstream_remote upstream_git \
    upstream_capped upstream_drop_refs upstream_pull_approved upstream_replay_tree upstream_pin_evidence upstream_row_suffix upstream_evidence; do
  eval "$(sed -n "/^$f() {/,/^}/p" "$script")"
  declare -F "$f" >/dev/null || fail "$f not found in pr-redteam"
done
upstream_max_pins=6 upstream_max_bytes=100000 upstream_max_commits=50 upstream_fetch_timeout=20
upstream_max_branches=8 upstream_max_pull_pages=10 upstream_min_share=1024
state="$t/state"; me=reviewer
base="file://$t/forge"; forge_host=forge.test; forge_aliases="" source_mappings=""
token_file="$t/token"; printf 'dummytoken' >"$token_file"; chmod 600 "$token_file"
mkdir -p "$t/home" "$t/pulls"; export HOME="$t/home" GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0

# The stand-in forge, per upstream repository acme/<name>: the repository read, its refs (main
# protected), the native pull request listing (no landing commits, as live), each pull request's
# reviews, and the GitHub-shaped closed listing that carries merge_commit_sha.
# $t/pulls/<name>.json holds [{number, head, base, merge, approved_head}] for that repository.
api() {
  echo "$2" >>"$t/api.log"; code=200
  local r="${2#/api/v[13]/repos/}" name n
  r="${r/\%2F//}"; name="${r#acme/}"; name="${name%%[/?]*}"
  case "$2" in
    /api/v1/repos/acme%2F*/refs)
      body="$(git -C "$t/forge/git/acme/$name.git" for-each-ref --format='%(refname:strip=2) %(objectname)' refs/heads/ |
        jq -Rc 'split(" ") | {name: .[0], sha: .[1], kind: "branch", protected: (.[0] == "main")}' | jq -sc .)" ;;
    /api/v1/repos/acme%2F*/pulls\?state=all*)
      body="$(jq -c '{items: map({number, state: "merged", title: "t", head_ref: "f", base_ref: "main", head_sha: .head, base_sha: .base}),
        page: {has_more: false}}' "$t/pulls/$name.json")" ;;
    /api/v1/repos/acme%2F*/pulls/[0-9]*)
      n="${2##*/}"
      body="$(jq -c --argjson n "$n" --arg me "$me" '(.[] | select(.number == $n)) as $p
        | {summary: {author: "dev"}, reviews: [{author: $me, state: "APPROVED", head_sha: $p.approved_head, effective: true, stale: false}]}' \
        "$t/pulls/$name.json")" ;;
    /api/v3/repos/acme/*/pulls\?state=closed*)
      if [ -e "$t/v3-down" ]; then code=500; body='{"message":"down"}'
      else
        # A forge that clamps per_page ($t/v3-clamp): one row per page, newest first; otherwise all on page 1.
        body="$(jq -c --argjson p "${2##*page=}" --argjson clamp "$( [ -e "$t/v3-clamp" ] && echo true || echo false)" '
          map({number, title: "t", merged_at: "2026-10-26T00:00:00Z", merge_commit_sha: .merge,
               head: {ref: "f", sha: .head}, base: {ref: "main", sha: .base}}) | reverse
          | if $clamp then .[($p - 1):$p] elif $p == 1 then . else [] end' "$t/pulls/$name.json")"
      fi ;;
    /api/v1/repos/acme%2F*)
      body="$(jq -nc --arg n "$name" '{default_branch: "main", id: {owner: "acme", name: $n}}')" ;;
    *) echo "$2" >>"$t/api.unexpected"; code=404; body='{}' ;;
  esac
}

# An upstream repository: main w0, then the history a scenario builds; pull request heads are kept
# under refs/pull/<n>/head on the forge so a review can fetch them by id.
W=""; NAME=""; when=1700000000
u() { git -C "$W" -c user.name=queue -c user.email=queue@example.invalid "$@"; }
commit() { # message [author] -> sha
  when=$((when + 60)); echo "$1 $when" >"$W/$1.txt"; u add -A
  GIT_AUTHOR_NAME="${2:-dev}" GIT_AUTHOR_EMAIL="${2:-dev}@example.invalid" GIT_AUTHOR_DATE="@$when +0000" \
    u -c core.hooksPath=/dev/null commit -qm "$1"; u rev-parse HEAD
}
upstream() { # name
  NAME="$1"; W="$t/w-$1"; git init -q -b main "$W"; echo start >"$W/file"; seq 1 10 >"$W/shared.txt"
  u add file shared.txt; u commit -qm w0
  w0="$(u rev-parse HEAD)"
}
replay() { # head [reverse] -> replays the commits of head (from its merge base) onto main, in order or reversed
  local h="$1" mb c order=--reverse; mb="$(u merge-base "$h" main)"
  [ "${2:-}" != reverse ] || order=--topo-order
  for c in $(u rev-list "$order" "$h" "^$mb"); do u cherry-pick --allow-empty --keep-redundant-commits "$c" >/dev/null; done
  u rev-parse HEAD
}
# Rewrites the landing's last commit keeping its author, author date and message: only content moves.
same_meta() { # how: alter|extra|drop
  case "$1" in
    alter) echo "something else" >"$W/two-b.txt" ;;
    extra) echo "an unreviewed hunk" >"$W/smuggled.txt" ;;
    drop) rm "$W/two-b-also.txt" ;;
    indent) sed -i 's/^/    /' "$W/two-b.txt" ;;
    misplace) git -C "$W" show HEAD~1:rep.txt >"$W/rep.txt"; sed -i '11a X' "$W/rep.txt" ;;
  esac
  u add -A; u commit -q --amend --no-edit; u rev-parse HEAD
}
publish() { # pulls-json: puts the forge copy and the pull request heads in place
  rm -rf "$t/forge/git/acme/$NAME.git"; mkdir -p "$t/forge/git/acme"
  git clone -q --bare "$W" "$t/forge/git/acme/$NAME.git"
  printf '%s\n' "$1" >"$t/pulls/$NAME.json"
  jq -r '.[] | "\(.number) \(.head)"' <<<"$1" | while read -r n h; do
    git -C "$t/forge/git/acme/$NAME.git" update-ref "refs/pull/$n/head" "$h"
  done
}
evidence() { # old new -> review dir (a dependent bumping acme/<name> from old to new)
  local D="$t/dep-$NAME-$RANDOM" o b; git init -q -b main "$D"
  pin() { printf '[package]\nname = "dep"\n\n[dependencies]\nweb = { git = "https://forge.test/git/acme/%s.git", rev = "%s" }\n' "$NAME" "$1" >"$D/Cargo.toml"; }
  snap() { git -C "$D" add -A; git -C "$D" -c user.name=t -c user.email=t@t commit -q -m s; git -C "$D" rev-parse HEAD; }
  pin "$1"; b="$(snap)"; pin "$2"
  o="$(mktemp -d "$t/out-XXXXXX")"; : >"$t/api.log"
  upstream_evidence "$D/.git" "$b" "$(snap)" "$o" acme "${budget:-100000}"; echo "$o"
}
pin_of() { echo "$1/upstream/acme@$NAME-${2:0:12}/pin.json"; }

# The shape of the real range: one pull request landing fast-forward at its own head, then one
# whose two commits were written on an older base and replayed by the queue, then a one-commit
# replay. pulls: #1 head h1 = merge h1; #2 head p2 (2 commits) -> landed a2,b2; #3 head p3 -> x3.
scenario() { # name [extra steps between landings: push|squash|edit|tail]
  local mode="${2:-$1}"
  upstream "$1"
  # shift: #1 changes line 3 of shared.txt and #2's last commit line 5, so #2's replay is clean but its
  # context moved (its patch-id differs). conflict: both change line 5.
  u checkout -qb pr1
  case "$mode" in shift*) sed -i 's/^3$/three (#1)/' "$W/shared.txt" ;; conflict) sed -i 's/^5$/five (#1)/' "$W/shared.txt" ;;
    lineshift) sed -i '1i top-1\ntop-2\ntop-3\ntop-4\ntop-5\ntop-6' "$W/shared.txt" ;; esac
  h1="$(commit one)"
  u checkout -qb pr2 "$w0"
  # misplace: two-a adds two identical blocks and two-b inserts a line into the first, so a hunk
  # placed in the second block has the very same text and context, only other line numbers.
  [ "$mode" != misplace ] || { printf '%s\n' a b c d e f g a b c d e f g >"$W/rep.txt"; }
  # lineshift: #1 adds lines at the top of shared.txt, which moves #2's hunk without touching its context.
  commit two-a >/dev/null
  [ "$mode" != misplace ] || sed -i '4a X' "$W/rep.txt"
  [ "$mode" != empty ] || u commit -q --allow-empty -m "two-empty"
  case "$mode" in shift*|conflict) sed -i 's/^5$/five (#2)/' "$W/shared.txt" ;; lineshift) sed -i 's/^9$/nine (#2)/' "$W/shared.txt" ;; esac
  echo also >"$W/two-b-also.txt"; p2="$(commit two-b)"
  u checkout -q main; u merge -q --ff-only pr1
  [ "$mode" != push ] || direct="$(commit direct-push other)"
  if [ "$mode" = conflict ]; then
    # The replay of two-b conflicts on line 5; the landing is a hand resolution keeping #2's line,
    # under two-b's own author, date and message.
    u cherry-pick "$(u rev-parse "$p2~1")" >/dev/null
    a2="$(u rev-parse HEAD)"
    git -C "$W" checkout -q "$p2" -- two-b.txt two-b-also.txt; sed -i 's/^five (#1)$/five (#2)/' "$W/shared.txt"; u add -A
    b2="$(GIT_AUTHOR_NAME="$(u log -1 --format=%an "$p2")" GIT_AUTHOR_EMAIL="$(u log -1 --format=%ae "$p2")" \
      GIT_AUTHOR_DATE="$(u log -1 --format=%aI "$p2")" u commit -q -m "$(u log -1 --format=%B "$p2")" && u rev-parse HEAD)"
  elif [ "$mode" = squash ]; then
    u merge -q --squash pr2 >/dev/null 2>&1
    b2="$(GIT_AUTHOR_DATE="@$((when + 5)) +0000" u commit -qm squashed && u rev-parse HEAD)"; a2=""
  else
    b2="$(replay "$p2" "$( [ "$mode" != reorder ] || echo reverse)")"; a2="$(u rev-parse "$b2~1")"
    if [ "$mode" = edit ]; then u commit -q --amend -m "two-b, reworded"; b2="$(u rev-parse HEAD)"; fi
    case "$mode" in alter|extra|drop|indent|misplace) b2="$(same_meta "$mode")" ;; shift-alter|shift-extra) b2="$(same_meta "${mode#shift-}")" ;; esac
  fi
  u checkout -qb pr3 "$b2"; p3="$(commit three)"
  # #3 was written on #2's landing, then main moved on with nothing else, so the queue replays it as is
  # but under a new committer: a different commit with the same author, date and message.
  u checkout -q main; x3="$(GIT_COMMITTER_DATE="@$((when + 30)) +0000" replay "$p3")"
  [ "$mode" != tail ] || tailc="$(commit after-last-landing other)"
  tip="$(u rev-parse main)"
}
pulls() { # [p2-merge] -> pulls json
  jq -nc --arg h1 "$h1" --arg w0 "$w0" --arg p2 "$p2" --arg m2 "${1-$b2}" --arg p3 "$p3" --arg b2 "$b2" --arg x3 "$x3" \
    --arg ap2 "${approved_p2:-$p2}" '
    [{number: 1, head: $h1, base: $w0, merge: $h1, approved_head: $h1},
     {number: 2, head: $p2, base: $w0, merge: (if $m2 == "" then null else $m2 end), approved_head: $ap2},
     {number: 3, head: $p3, base: $b2, merge: $x3, approved_head: $p3}]'
}
arr() { jq -r "$2" "$1"; }

# 1. Every commit of the range is attributed: #1 by its own head, #2 and #3 by their landings.
scenario ok; publish "$(pulls)"
o="$(evidence "$w0" "$tip")"; p="$(pin_of "$o" "$tip")"; dir="$(dirname "$p")"
[ "$(arr "$p" .status)" = merged-tip ] && [ "$(arr "$p" .already_reviewed_upstream)" = true ] && [ "$(arr "$p" .diff.fetched)" = false ] \
  && [ ! -e "$dir/diff.patch" ] || fail "a range landed through the queue is not already reviewed: $(cat "$p")"
[ "$(jq -c --arg h1 "$h1" --arg a2 "$a2" --arg b2 "$b2" --arg x3 "$x3" '[.commit_pulls[$h1], .commit_pulls[$a2], .commit_pulls[$b2], .commit_pulls[$x3]]' "$p")" = '[1,2,2,3]' ] \
  || fail "commit_pulls: $(jq -c .commit_pulls "$p")"
jq -e '[.landing_pulls[] | select(.kind == "replay") | .methods[]] | . == ["replay_tree", "replay_tree", "replay_tree"]' "$p" >/dev/null \
  || fail "every replayed commit is attributed by its exact replayed tree: $(jq -c .landing_pulls "$p")"
jq -e --arg a2 "$a2" --arg b2 "$b2" '.landing_pulls | map(select(.kind == "replay" and .attributed)) | map(.number) == [2, 3]
  and (map(select(.number == 2))[0].landing_commits == [$a2, $b2])' "$p" >/dev/null || fail "landing_pulls: $(jq -c .landing_pulls "$p")"
[ "$(jq -c '[.approved_pulls[].number] | sort' "$p")" = '[1,2,3]' ] || fail "approved_pulls: $(jq -c .approved_pulls "$p")"
jq -e --arg h1 "$h1" '.landing_pulls | map(select(.kind == "own-head")) == [{number: 1, kind: "own-head", head_sha: $h1,
  merge_commit_sha: $h1, landing_commits: [$h1], methods: null, attributed: true, reason: null}]' "$p" >/dev/null \
  || fail "the own-head landing is not recorded: $(jq -c .landing_pulls "$p")"
grep -qx '/api/v3/repos/acme/ok/pulls?state=closed&per_page=100&page=1' "$t/api.log" || fail "the landing listing was not read: $(cat "$t/api.log")"
ok 'replayed landings that line up with approved pull requests are already reviewed upstream; the diff is not fetched'

keeps_diff() { # label reason-needle
  local o p; o="$(evidence "$w0" "$tip")"; p="$(pin_of "$o" "$tip")"
  [ "$(arr "$p" .already_reviewed_upstream)" = false ] && [ "$(arr "$p" .diff.fetched)" = true ] \
    || fail "$1 skipped the diff: $(cat "$p")"
  [ -z "${2:-}" ] || jq -e --arg w "$2" '.landing_pulls | any(.attributed == false and ((.reason // "") | contains($w)))' "$p" >/dev/null \
    || fail "$1: reason '$2' not recorded: $(jq -c .landing_pulls "$p")"
  LAST="$p"
}

# 1-evidence. The packet shows what the attribution used (jeryu-deploy#498's shape: every commit is
# a replayed landing, so no native listing row has any of them as its head). pulls.json carries each
# named pull request with its head, base, merged state, landing commit and approval head, and the
# counters and notes agree with commit_pulls.
jq -e --arg h1 "$h1" --arg p2 "$p2" --arg b2 "$b2" --arg p3 "$p3" --arg x3 "$x3" '
  (map({key: (.number | tostring), value: .}) | from_entries) as $r
  | $r["1"].head_sha == $h1 and $r["1"].approval_head == $h1 and $r["1"].merged == true and $r["1"].base_ref == "main"
  and $r["2"].head_sha == $p2 and $r["2"].merge_sha == $b2 and $r["2"].approval_head == $p2 and $r["2"].merged == true
      and $r["2"].base_ref == "main" and $r["2"].source == "closed-listing"
  and $r["3"].head_sha == $p3 and $r["3"].merge_sha == $x3 and $r["3"].approval_head == $p3' "$dir/pulls.json" >/dev/null \
  || fail "pulls.json does not carry the attributed pull requests: $(cat "$dir/pulls.json")"
jq -e --slurpfile pl "$dir/pulls.json" '([.commit_pulls[]] + [.approved_pulls[].number] + [.landing_pulls[] | select(.attributed) | .number] | unique)
  - [$pl[0][].number] == [] and .pulls.commits_without_pull == 0' "$p" >/dev/null \
  || fail "pin.json names pull requests pulls.json does not show, or its counter disagrees: $(jq -c .pulls "$p")"
! grep -q 'attributed to no pull request\|no pull request.s head' "$dir/note.txt" || fail "note.txt contradicts the attribution: $(cat "$dir/note.txt")"
ok 'pulls.json carries every pull request pin.json names, and the counters and notes agree with the attribution'

# 1-withdrawn. When the evidence for the attributed pull requests cannot be shipped (here, pulls.json
# with the landing rows is over its share of a small budget), the attribution is withdrawn: the diff
# is fetched, and pin.json names no pull request pulls.json does not show.
o="$(budget=2400 evidence "$w0" "$tip")"; p="$(pin_of "$o" "$tip")"; dir="$(dirname "$p")"
[ "$(arr "$p" .already_reviewed_upstream)" = false ] && [ "$(arr "$p" .diff.fetched)" = true ] \
  && grep -q 'the attribution is withdrawn because its evidence is not in this packet' "$dir/note.txt" \
  || fail "evidence that does not fit did not withdraw the attribution: $(cat "$p")"
jq -e --slurpfile pl "$dir/pulls.json" '([.commit_pulls[] | select(. != null)] + [.approved_pulls[].number] + [.landing_pulls[].number] | unique)
  - [$pl[0][].number] == [] and .pulls.commits_without_pull == ([.commit_pulls[] | select(. == null)] | length)
  and .pulls.commits_without_pull > 0' "$p" >/dev/null \
  || fail "a withdrawn attribution still names pull requests pulls.json lacks: $(jq -c '{commit_pulls, pulls}' "$p"; cat "$dir/pulls.json")"
grep -q "of the range's commits are attributed to no pull request in pulls.json" "$dir/note.txt" || fail "the withdrawn count is not noted"
ok 'evidence that cannot be shipped withdraws the attribution; the diff is fetched and pin.json stays consistent with pulls.json'

# 1a. A pin whose every commit is attributed through its own pull request's review diff reads no
# landing listing at all.
upstream onlyheads; u checkout -qb pr1; h1="$(commit one)"; u checkout -q main; u merge -q --ff-only pr1; tip="$h1"
publish "$(jq -nc --arg h1 "$h1" --arg w0 "$w0" '[{number: 1, head: $h1, base: $w0, merge: $h1, approved_head: $h1}]')"
o="$(evidence "$w0" "$tip")"; p="$(pin_of "$o" "$tip")"
[ "$(arr "$p" .already_reviewed_upstream)" = true ] && ! grep -q 'pulls?state=closed' "$t/api.log" \
  || fail "a pin attributed by review diffs alone read the landing listing: $(cat "$t/api.log")"
ok 'a pin whose commits are all in approved review diffs does not read the landing listing'

# 1b. A forge that clamps per_page returns short pages: the listing is read to its empty page, so
# every landing is still found; a page cap reached on a page with rows is noted, and keeps the diff.
scenario clamp; publish "$(pulls)"; touch "$t/v3-clamp"
o="$(evidence "$w0" "$tip")"; p="$(pin_of "$o" "$tip")"
[ "$(arr "$p" .already_reviewed_upstream)" = true ] && [ "$(grep -c 'pulls?state=closed' "$t/api.log")" = 4 ] \
  || fail "short pages ended the landing listing: $(grep closed "$t/api.log"; jq -c .landing_pulls "$p")"
upstream_max_pull_pages=1 keeps_diff "a landing listing cut by the page cap"
grep -q 'read to the 1-page cap before every unattributed landing was found' "$(dirname "$LAST")/note.txt" || fail "the cap is not noted"
rm "$t/v3-clamp"
ok 'a clamped landing listing is read to its empty page; hitting the page cap is noted and keeps the diff'

# 2. A direct push between two landings lengthens the next landing's run: not attributed.
scenario push; publish "$(pulls)"; keeps_diff "a direct push before a landing" "the landing has 3 commits and the pull request 2"
[ "$(jq -r --arg d "$direct" '.commit_pulls[$d]' "$LAST")" = null ] || fail "the direct push was attributed"
ok 'a direct push between landings keeps the diff and is attributed to nothing'

# 3. A squash landing (one commit for two) does not line up.
scenario squash; publish "$(pulls)"; keeps_diff "a squash landing" "the landing has 1 commits and the pull request 2"
ok 'a squash landing keeps the diff'

# 4. A replay whose message differs from the approved commit does not line up.
scenario edit; publish "$(pulls)"; keeps_diff "an edited replay" "authors, dates or messages differ"
ok 'a replay that is not the approved commits (here, a reworded message) keeps the diff'

# 4b. Content, not metadata: a landing commit with the replayed commit's author, author date and
# message but other content is not that commit. Altered, extra and dropped hunks, and a reordered
# replay, all keep the diff.
for m in alter extra drop; do
  scenario "$m"; publish "$(pulls)"
  keeps_diff "a landing with the same metadata but $m content" "the landed tree differs from the replayed one"
  [ "$(jq -r --arg b "$b2" '.commit_pulls[$b]' "$LAST")" = null ] || fail "$m: the altered commit was attributed"
  [ "$(u log -1 --format='%an %ae %aI %B' "$b2")" = "$(u log -1 --format='%an %ae %aI %B' "$p2")" ] \
    || fail "$m: the case does not copy the metadata, so it proves nothing"
done
ok 'a landing commit with copied metadata but altered, extra or dropped content is attributed to nothing'
scenario reorder; publish "$(pulls)"; keeps_diff "a reordered replay" "is not exactly"
ok 'a replay of the right commits in the wrong order keeps the diff'
scenario empty; publish "$(pulls)"; keeps_diff "a landing with an empty commit" "an empty commit (it changes nothing)"
ok 'a landing containing an empty commit keeps the diff'

# 4b'. Whitespace is content: a landing whose only difference is indentation, under copied
# metadata, is not attributed (git patch-id, which strips whitespace, would call them equal).
scenario indent; publish "$(pulls)"
[ "$(u diff-tree -p "$b2" | git patch-id --stable | cut -d' ' -f1)" = "$(u diff-tree -p "$p2" | git patch-id --stable | cut -d' ' -f1)" ] \
  || fail "the indentation case does not fool patch-id, so it proves nothing"
keeps_diff "an indentation-only change under copied metadata" "the landed tree differs from the replayed one"
ok 'an indentation-only change under copied metadata is not attributed'
# The same hunk text placed at other line numbers (here, into an identical second block) is other
# content; a hunk moved only because lines were added above it is the same content.
scenario misplace; publish "$(pulls)"
[ "$(u diff-tree -p "$b2" | git patch-id --stable | cut -d' ' -f1)" = "$(u diff-tree -p "$p2" | git patch-id --stable | cut -d' ' -f1)" ] \
  || fail "the misplaced-hunk case does not fool patch-id, so it proves nothing"
keeps_diff "identical hunk text at other line numbers" "the landed tree differs from the replayed one"
scenario lineshift; publish "$(pulls)"
o="$(evidence "$w0" "$tip")"; p="$(pin_of "$o" "$tip")"
[ "$(arr "$p" .already_reviewed_upstream)" = true ] \
  && [ "$(jq -c '.landing_pulls | map(select(.number == 2))[0].methods' "$p")" = '["replay_tree","replay_tree"]' ] \
  || fail "a hunk moved by lines added above it: $(jq -c .landing_pulls "$p")"
ok 'a hunk at other line numbers is attributed only when the replayed tree is exact'

# 4c. A replay whose context moved: the patch-id differs, but a three-way replay of the reviewed
# commit onto the landing's parent writes exactly the landed tree, so it is attributed (replay_tree).
scenario shift; publish "$(pulls)"
o="$(evidence "$w0" "$tip")"; p="$(pin_of "$o" "$tip")"
[ "$(arr "$p" .already_reviewed_upstream)" = true ] \
  && [ "$(jq -c '.landing_pulls | map(select(.number == 2))[0].methods' "$p")" = '["replay_tree","replay_tree"]' ] \
  && [ "$(jq -c '.landing_pulls | map(select(.number == 3))[0].methods' "$p")" = '["replay_tree"]' ] \
  || fail "a shifted-context replay: $(jq -c .landing_pulls "$p")"
[ "$(u diff "$p2~1" "$p2" | git patch-id --stable | cut -d' ' -f1)" != "$(u diff "$b2~1" "$b2" | git patch-id --stable | cut -d' ' -f1)" ] \
  || fail "the shifted case does not move the context, so it proves nothing"
ok 'a replay whose context moved is attributed by its exact replayed tree; the method is recorded per commit'
# Altered content under copied metadata, on a shifted replay too: neither method attributes it.
for m in alter extra; do
  scenario "shift-$m"; publish "$(pulls)"
  keeps_diff "altered content ($m) under either method" "the landed tree differs from the replayed one"
  [ "$(u log -1 --format='%an %ae %aI %B' "$b2")" = "$(u log -1 --format='%an %ae %aI %B' "$p2")" ] \
    || fail "shift-$m: the case does not copy the metadata, so it proves nothing"
done
ok 'altered or extra content under copied metadata on a shifted replay is not attributed'
scenario conflict; publish "$(pulls)"; keeps_diff "a conflicting replay" "the replay conflicts"
ok 'a replay that conflicts (here, resolved by hand) keeps the diff'
# A git without `merge-tree --write-tree --merge-base` (before 2.40) answers 129: that fails closed.
scenario shift-oldgit shift; publish "$(pulls)"
git() { if [ "${3:-}" = merge-tree ]; then echo "error: unknown option" >&2; return 129; fi; command git "$@"; }
keeps_diff "a git without merge-tree --merge-base" "needs git 2.40 or later"
unset -f git
ok 'a git that cannot replay a tree (before 2.40) fails closed and says so'

# 5. A commit after the last landing belongs to no pull request.
scenario tail; publish "$(pulls)"; keeps_diff "a commit after the last landing"
[ "$(jq -r --arg c "$tailc" '.commit_pulls[$c]' "$LAST")" = null ] || fail "the trailing push was attributed"
ok 'a direct push after the last landing keeps the diff'

# 6. No landing commit recorded for #2: its replayed commits are attributed to nothing.
scenario nomerge; publish "$(pulls "")"; keeps_diff "a missing merge_commit_sha"
[ "$(jq -r --arg b "$b2" '.commit_pulls[$b]' "$LAST")" = null ] || fail "a landing without merge_commit_sha was attributed"
ok 'a landing the forge records no merge_commit_sha for keeps the diff'

# 7. This reviewer's approval is on another head of #2.
scenario otherhead; approved_p2="$h1" publish "$(approved_p2="$h1" pulls)"; keeps_diff "an approval on another head" "no effective approval"
ok 'a landing whose pull request this reviewer did not approve at its head keeps the diff'

# 8. The landing listing cannot be read.
scenario down; publish "$(pulls)"; touch "$t/v3-down"; keeps_diff "an unreadable landing listing"
grep -q 'landing commits of acme/down' "$(dirname "$LAST")/note.txt" || fail "the unreadable listing is not noted"
rm "$t/v3-down"
ok 'an unreadable landing listing keeps the diff and says so'

# 9. The old pin sits inside a landing (between #2's two replayed commits): that run is short.
scenario mid; publish "$(pulls)"
o="$(evidence "$a2" "$tip")"; p="$(pin_of "$o" "$tip")"
[ "$(arr "$p" .already_reviewed_upstream)" = false ] && jq -e '.landing_pulls | any(.number == 2 and .attributed == false)' "$p" >/dev/null \
  || fail "a landing cut by the old pin was attributed: $(cat "$p")"
ok 'a landing that began before the old pin keeps the diff'

[ ! -s "$t/api.unexpected" ] || fail "the evidence code called forge paths the stub does not model: $(sort -u "$t/api.unexpected")"
echo "QUEUE LANDING PASS"
