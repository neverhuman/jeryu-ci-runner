#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# probe-forge-per-base.sh -- does the forge this runner talks to *evaluate*
# branch protection per base, or only read status rollups per base?
#
# docs/pr-gate-per-base-required.md section 3. Reading per base does not prove
# evaluating per base, and the pinned forge source is not the deployed forge,
# so PR_GATE_PER_BASE stays off until this probe has passed against the forge
# the runner posts to, and the operator has recorded its output.
#
# Not part of ops/pr-gate/tests/required.sh: it needs a forge, two credentials
# and a scratch repository. It takes every one of them from its arguments and
# reads nothing from the environment, so no gate can run it by accident and no
# environment can redirect it at a repository that matters.
#
#   probe-forge-per-base.sh --forge URL --owner OWNER --repo NAME \
#     --author-token-file F --runner-token-file F [--context CTX] \
#     [--fixture-out PATH] [--work-dir DIR] [--allow-passport-only]
#
# Two credentials, not one: the forge refuses a required status produced by the
# author of the change it vouches for (jeryu-deploy `status_producer_refusal`),
# so the statuses must come from a principal that did not open the pull
# requests. The probe checks the two logins differ before it asserts anything.
#
# Both principals need push access under --owner: the author token creates the
# scratch repository, pushes its branches and opens the pull requests, and the
# runner token posts the statuses and performs the independent merge. The probe stops with the forge's own status
# code the first time either is refused, so a missing permission reads as a
# refusal and never as a per-base answer.
#
# It creates the scratch repository and leaves it archived; it never touches a
# repository that already exists. The scratch clone goes under --work-dir (a
# fresh directory under this checkout’s target/ by default).
# ---------------------------------------------------------------------------
set -euo pipefail

usage() { sed -n '3,33p' "$0" >&2; exit 2; }

forge="" owner="" repo="" author_token="" runner_token="" context=""
fixture_out="" work_dir="" passport_only=0
while (($#)); do case "$1" in
  --forge) forge="${2:?--forge needs a URL}"; shift 2;;
  --owner) owner="${2:?--owner needs a name}"; shift 2;;
  --repo) repo="${2:?--repo needs a name}"; shift 2;;
  --author-token-file) author_token="${2:?}"; shift 2;;
  --runner-token-file) runner_token="${2:?}"; shift 2;;
  --context) context="${2:?}"; shift 2;;
  --fixture-out) fixture_out="${2:?}"; shift 2;;
  --work-dir) work_dir="${2:?}"; shift 2;;
  # The merge-path proof needs a head whose only required context is the gate's
  # own. On a forge that requires jankurai/proof of every head a scratch
  # repository can never be mergeable, and the proof rests on the forge's own
  # merge-passport answer per pull request instead. The operator says so here,
  # explicitly, rather than the probe quietly settling for less.
  --allow-passport-only) passport_only=1; shift;;
  *) printf 'unknown argument: %s\n' "$1" >&2; usage;;
esac; done
forge="${forge%/}"
[[ -n "$forge" && -n "$owner" && -n "$repo" && -n "$author_token" && -n "$runner_token" ]] || usage
[[ "$owner" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || { printf 'invalid --owner\n' >&2; exit 2; }
[[ "$repo" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || { printf 'invalid --repo\n' >&2; exit 2; }
[[ -r "$author_token" && -r "$runner_token" ]] || { printf 'both token files must be readable\n' >&2; exit 2; }
context="${context:-$repo/required}"
for tool in curl jq git; do command -v "$tool" >/dev/null || { printf '%s is required\n' "$tool" >&2; exit 2; }; done

say() { printf 'probe: %s\n' "$*"; }
failures=0
evidence=""
fail() { printf 'probe FAIL: %s\n' "$*" >&2; [[ -z "$evidence" ]] || printf '%s\n' "$evidence" >&2; failures=$((failures + 1)); }
ok() { printf 'probe ok: %s\n' "$*"; }

# Keep every Git fixture in owned physical target storage. A caller supplies a
# parent, never an existing tree that the probe could overwrite or remove.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
storage="$repo_root/target"
[[ "$repo_root" != /tmp && "$repo_root" != /tmp/* && ! -L "$storage" ]] || {
  printf 'probe storage must be outside /tmp and cannot be a symlink\n' >&2; exit 2;
}
mkdir -p "$storage"
parent="${work_dir:-$storage}"
[[ -d "$parent" && ! -L "$parent" && -O "$parent" ]] || {
  printf '--work-dir must be an owned physical directory under target\n' >&2; exit 2;
}
parent="$(cd "$parent" && pwd -P)"
[[ "$parent" == "$storage" || "$parent" == "$storage/"* ]] || {
  printf '--work-dir must be under this checkout target\n' >&2; exit 2;
}
work="$(mktemp -d "$parent/pr-gate-probe.XXXXXXXX")"
chmod 700 "$work"
cleanup() { rm -f -- "$work/auth-author" "$work/auth-runner"; }
trap cleanup EXIT
# The tokens reach curl through 0600 config files, never through argv: the same
# rule the runner follows (pr-gate-runner.sh, AUTH_CONFIG).
for who in author runner; do
  cfg="$work/auth-$who"; : >"$cfg"; chmod 600 "$cfg"
  token_file=$author_token; [[ "$who" == author ]] || token_file=$runner_token
  printf 'header = "Authorization: Bearer %s"\n' "$(cat "$token_file")" >"$cfg"
done

code="" body=""
api() { # who method path [json]
  local args=(--silent --show-error --max-time 60 -X "$2"
    --config "$work/auth-$1" -H 'Accept: application/json') out
  [[ -z "${4:-}" ]] || args+=(-H 'Content-Type: application/json' --data "$4")
  out="$(curl "${args[@]}" -w '\n%{http_code}' "$forge$3")" || out=$'\n000'
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
}

login_of() { # who
  api "$1" GET /api/v3/user
  [[ "$code" == 200 ]] || { printf 'GET /user with the %s token answered %s\n' "$1" "$code" >&2; exit 1; }
  jq -r '.login // ""' <<<"$body"
}
author_login=$(login_of author)
runner_login=$(login_of runner)
[[ -n "$author_login" && -n "$runner_login" ]] || { printf 'the forge named no login for a token\n' >&2; exit 1; }
[[ "$author_login" != "$runner_login" ]] || {
  printf 'the two tokens are the same principal (%s); the forge refuses a status produced by the author\n' \
    "$author_login" >&2; exit 2; }
say "author $author_login, status producer $runner_login, context $context"

# 1. A scratch repository of its own. An existing name is refused rather than reused.
api author GET "/api/v3/repos/$owner/$repo"
[[ "$code" == 404 ]] || { printf '%s/%s already exists (GET answered %s); pass an unused --repo\n' \
  "$owner" "$repo" "$code" >&2; exit 2; }
api author POST /api/v3/repos "$(jq -nc --arg n "$repo" --arg o "$owner" '{name: $n, owner: $o}')"
[[ "$code" =~ ^(200|201)$ ]] || { printf 'creating %s/%s answered %s: %s\n' "$owner" "$repo" "$code" "$body" >&2; exit 1; }
say "created $owner/$repo"
printf 'probe: when this run ends, archive or remove the scratch repository %s/%s\n' "$owner" "$repo"

# 2. One commit as the head of two pull requests, into two protected bases.
tree="$work/tree"
mkdir "$tree"
# shellcheck disable=SC2016  # expanded by git's helper shell, not here
git_helper='!f() { [ "$3" = get ] || exit 0; printf "username=%s\npassword=%s\n" "$1" "$(cat "$2")"; }; f'
git_env=(GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=2
  GIT_CONFIG_KEY_0="credential.$forge/git/.helper" GIT_CONFIG_VALUE_0=""
  GIT_CONFIG_KEY_1="credential.$forge/git/.helper"
  GIT_CONFIG_VALUE_1="$git_helper '$author_login' '$author_token'")
g() { env "${git_env[@]}" git -C "$tree" "$@"; }
git -C "$tree" init --quiet --initial-branch=main
g config user.name "pr-gate probe"
g config user.email "pr-gate-probe@invalid"
printf 'per-base probe\n' >"$tree/README.md"
g add README.md
g commit --quiet -m 'probe base commit'
remote="$forge/git/$owner/$repo.git"
g push --quiet "$remote" main:refs/heads/main
g push --quiet "$remote" main:refs/heads/release/probe
printf 'head\n' >"$tree/head.txt"
g add head.txt
g commit --quiet -m 'probe head commit'
g push --quiet "$remote" main:refs/heads/probe-head
head_sha=$(g rev-parse HEAD)
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || { printf 'no head sha\n' >&2; exit 1; }
say "head $head_sha on probe-head, bases main and release/probe"

protect() { # branch
  api author PUT "/api/v3/repos/$owner/$repo/branches/$1/protection" \
    "$(jq -nc --arg c "$context" '{required_status_checks: [$c], required_approving_review_count: 0,
      enforce_admins: true, require_jankurai_proof: false}')"
  [[ "$code" == 200 ]] || { printf 'protecting %s answered %s: %s\n' "$1" "$code" "$body" >&2; exit 1; }
  # Read it back: a rule the forge stored differently is not the rule asserted below.
  api author GET "/api/v3/repos/$owner/$repo/branches/$1/protection"
  jq -e --arg c "$context" '.required_status_checks.contexts | index($c)' <<<"$body" >/dev/null \
    || { printf '%s does not require %s after being protected: %s\n' "$1" "$context" "$body" >&2; exit 1; }
}
protect main
protect release%2Fprobe

open_pr() { # base
  api author POST "/api/v3/repos/$owner/$repo/pulls" \
    "$(jq -nc --arg b "$1" '{title: ("probe into " + $b), head: "probe-head", base: $b}')"
  [[ "$code" =~ ^(200|201)$ ]] || { printf 'opening a PR into %s answered %s: %s\n' "$1" "$code" "$body" >&2; exit 1; }
  jq -r '.number' <<<"$body"
}
pr_main=$(open_pr main)
pr_release=$(open_pr release/probe)
say "PR #$pr_main into main, PR #$pr_release into release/probe, same head"

# 3. The forge's own per-pull-request answer, not a status rollup: the merge
# passport the merge action itself checks (jeryu-deploy web/pulls.rs), whose
# required contexts come from `combined_status_for_base` for that PR's base.
passport() { # number -> sets body
  api author GET "/api/v1/repos/$owner%2F$repo/pulls/$1"
  [[ "$code" == 200 ]] || { printf 'reading the detail of #%s answered %s: %s\n' "$1" "$code" "$body" >&2; exit 1; }
}
# Whether the gate's own context is what blocks this pull request, and how.
gate_blocker() { # number
  passport "$1"
  jq -r --arg c "$context" '[.merge_passport.blockers[]? | select(.message | contains("`" + $c + "`"))]
    | if length == 0 then "none" else (.[0].code) end' <<<"$body"
}
other_blockers() { # number
  passport "$1"
  jq -r --arg c "$context" '[.merge_passport.blockers[]? | select(.message | contains("`" + $c + "`") | not)
    | .code] | join(",")' <<<"$body"
}
expect_blocker() { # number want why
  local got
  got=$(gate_blocker "$1")
  evidence="  #$1 merge_passport: $(jq -c '.merge_passport' <<<"$body")"
  if [[ "$got" == "$2" ]]; then ok "$3 (#$1: $got)"; else fail "$3: #$1 is $got, expected $2"; fi
  evidence=""
}

expect_blocker "$pr_main" passport_blocked_checks_missing "protection holds a head with no result"
expect_blocker "$pr_release" passport_blocked_checks_missing "protection holds the release head too"
((failures == 0)) || { printf 'probe FAILED: protection is not in force on the scratch repository\n' >&2; exit 1; }

foreign_main=$(other_blockers "$pr_main")
foreign_release=$(other_blockers "$pr_release")
merge_proof=1
if [[ -n "$foreign_main$foreign_release" ]]; then
  say "this forge holds the scratch heads for more than the gate's context (main: ${foreign_main:-none}, release: ${foreign_release:-none})"
  merge_proof=0
fi

post() { # state base -> 201 body in $body
  api runner POST "/api/v3/repos/$owner/$repo/statuses/$head_sha" \
    "$(jq -nc --arg s "$1" --arg c "$context" --arg b "$2" --arg d "pr-gate per-base probe" \
      '{state: $s, context: $c, description: $d} + (if $b == "" then {} else {base: $b} end)')"
  [[ "$code" == 201 ]] || { printf 'posting %s (base %s) answered %s: %s\n' "$1" "${2:-none}" "$code" "$body" >&2; exit 1; }
}

# 4. A success proved against release/probe alone.
post success release/probe
if [[ -n "$fixture_out" ]]; then
  printf '%s\n' "$body" >"$fixture_out"
  say "wrote the forge's own 201 body to $fixture_out"
fi
say "201 body of the base-scoped success: $(jq -c '{id, context, state, base}' <<<"$body")"
expect_blocker "$pr_release" none "a release/probe success satisfies the release pull request"
expect_blocker "$pr_main" passport_blocked_checks_missing "and does not satisfy the main pull request"

# 5. A failure proved against main does not touch the release line.
post failure main
expect_blocker "$pr_main" passport_blocked_checks "a main failure fails the main pull request"
expect_blocker "$pr_release" none "and leaves the release pull request satisfied"

# 6. A base-less row still answers for every base, in both directions: this is
# the fail-closed behaviour the base-not-kept supersede relies on (section 4).
post success ""
expect_blocker "$pr_main" none "a base-less success answers for main"
expect_blocker "$pr_release" none "a base-less success answers for release/probe"
post error ""
expect_blocker "$pr_main" passport_blocked_checks "a base-less error reds main"
expect_blocker "$pr_release" passport_blocked_checks "a base-less error reds release/probe"

# 7. The merge path itself, which is the only answer no reader can fake: with
# the release line green and main red, the main merge is refused and the
# release merge goes through.
post failure main
post success release/probe
expect_blocker "$pr_main" passport_blocked_checks "main is red again"
expect_blocker "$pr_release" none "release/probe is green again"
if ((merge_proof)); then
  api runner PUT "/api/v3/repos/$owner/$repo/pulls/$pr_main/merge" '{}'
  evidence="  merge #$pr_main -> $code: $body"
  if [[ "$code" == 405 ]]; then ok "the forge refuses to merge the main pull request"
  else fail "merging the main pull request answered $code, expected 405"; fi
  evidence=""
  api runner PUT "/api/v3/repos/$owner/$repo/pulls/$pr_release/merge" '{}'
  evidence="  merge #$pr_release -> $code: $body"
  if [[ "$code" == 200 ]]; then ok "and merges the release pull request on its own base's result"
  else fail "merging the release pull request answered $code, expected 200"; fi
  evidence=""
elif ((passport_only)); then
  say "merge-path proof not attempted on this forge; the operator accepted the passport evidence alone"
else
  fail "no merge-path proof on this forge: its heads carry required contexts the probe cannot satisfy.
  Re-run with --allow-passport-only to accept the per-pull-request passport evidence above instead."
fi

api author PATCH "/api/v3/repos/$owner/$repo" '{"archived": true}'
if [[ "$code" == 200 ]]; then say "archived the scratch repository $owner/$repo"
else say "could not archive $owner/$repo (PATCH answered $code); remove it by hand"; fi

if ((failures)); then
  printf 'probe FAILED (%s disagreement(s)): leave PR_GATE_PER_BASE off\n' "$failures" >&2
  exit 1
fi
printf 'probe PASSED: %s evaluates <repo>/required per base for %s/%s@%s\n' \
  "$forge" "$owner" "$repo" "${head_sha:0:12}"
