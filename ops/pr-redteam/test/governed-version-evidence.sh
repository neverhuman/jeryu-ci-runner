#!/usr/bin/env bash
# The functions under test read globals set here, so SC2034 does not apply to this file.
# shellcheck disable=SC2034
# Offline: a change that moves a consumer's generated `required_tool_version` gets governance/ --
# the governed tool manifest as a branch the stand-in forge reports protected holds it, the renderer
# sources that own the scalar, and the commit/tree/blob identities of those bytes -- and nothing the
# change itself carries picks any of it.
#   test/governed-version-evidence.sh      exit 0 when every case behaves
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../pr-redteam"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
fail() { echo "not ok - $1" >&2; exit 1; }
ok() { echo "ok - $1"; }
for f in upstream_remote upstream_git upstream_capped upstream_drop_refs \
    governed_is_sentinel governed_quoted_version governed_scalar_value governed_manifest_version \
    governed_scalar_moves governed_blob_copy governed_version_evidence; do
  eval "$(sed -n "/^$f() {/,/^}/p" "$script")"
  declare -F "$f" >/dev/null || fail "$f not found in pr-redteam"
done
upstream_max_branches=8 upstream_min_share=1024 upstream_fetch_timeout=20
state="$t/state"; me=reviewer
base="file://$t/forge"; forge_host=forge.test
token_file="$t/token"; printf 'dummytoken' >"$token_file"; chmod 600 "$token_file"
governed_authority_repo=jeryu-tool
governed_authority_manifest=tool-manifest.toml
governed_renderer_paths="ops/render-tool-manifest.sh crates/jeryu-tool-control/src/render_rules.rs"
governed_max_bytes=200000

# Ambient credentials that must never be used: a global helper that records any call and fails, and
# a netrc. Every git command below, the code under test included, runs with them in place.
mkdir -p "$t/home"
cat >"$t/ambient.gitconfig" <<CFG
[credential]
	helper = "!f() { echo called >>'$t/ambient-called'; exit 1; }; f"
CFG
printf 'machine 127.0.0.1 login ambient password netrcsecret\n' >"$t/home/.netrc"; chmod 600 "$t/home/.netrc"
export GIT_CONFIG_GLOBAL="$t/ambient.gitconfig" HOME="$t/home" GIT_TERMINAL_PROMPT=0

# The forge API: the repository read (default_branch) and /refs (name, sha, kind, protected), the
# only two reads this evidence makes. Any other path is recorded and fails the suite at the end.
stub_default=main stub_main_protected=true stub_side_protected=false
ref_rows() { # bare-repo
  git -C "$1" for-each-ref --format='%(refname:strip=2) %(objectname)' refs/heads/ |
    jq -Rc 'split(" ") | {name: .[0], sha: .[1], kind: "branch", protected: false}' | jq -sc .
}
api() {
  echo "$2" >>"$t/api.log"; code=200
  case "$2" in
    /api/v1/repos/acme%2Fjeryu-tool)
      body="$(jq -nc --arg d "$stub_default" '{default_branch: $d, archived: false, visibility: "private"}')" ;;
    /api/v1/repos/acme%2Fjeryu-tool/refs)
      body="$(ref_rows "$t/forge/git/acme/jeryu-tool.git" | jq -c --argjson mp "$stub_main_protected" --argjson sp "$stub_side_protected" '
        map(if .name == "main" then .protected = $mp elif .name == "side" then .protected = $sp else . end)')" ;;
    /api/v1/repos/acme%2Fghost|/api/v1/repos/acme%2Fghost/refs) code=404; body='{"error":{"code":"not_found"}}' ;;
    *) echo "$2" >>"$t/api.unexpected"; code=404; body='{"error":{"code":"not_found"}}' ;;
  esac
}

# The authority repository acme/jeryu-tool: main declares 1.7.6, the unprotected `side` branch
# declares 9.9.9 and carries no renderer at all.
manifest() { printf '# tool-manifest.toml\nschema_version = "1"\n\n[other]\nsemver = "0.0.1"\n\n[jankurai]\ntag = "v%s"\nsemver = "%s"\n' "$1" "$1"; }
a() { git -C "$t/authority" -c user.name=t -c user.email=t@t "$@"; }
git init -q -b main "$t/authority"
mkdir -p "$t/authority/ops" "$t/authority/crates/jeryu-tool-control/src"
manifest 1.7.6 >"$t/authority/tool-manifest.toml"
printf '#!/bin/sh\n# renders every consumer from tool-manifest.toml\n' >"$t/authority/ops/render-tool-manifest.sh"
printf 'if matches!(name, "audit-policy.toml") { replace(r"(required_tool_version = \\")[^\\"]*") }\n' \
  >"$t/authority/crates/jeryu-tool-control/src/render_rules.rs"
a add -A; a commit -qm "govern 1.7.6"
a checkout -qb side; manifest 9.9.9 >"$t/authority/tool-manifest.toml"
rm -r "$t/authority/ops" "$t/authority/crates"; a add -A; a commit -qm "unreviewed side"
a checkout -q main
mkdir -p "$t/forge/git/acme"; git clone -q --bare "$t/authority" "$t/forge/git/acme/jeryu-tool.git"
auth_commit="$(git -C "$t/forge/git/acme/jeryu-tool.git" rev-parse main)"
auth_tree="$(git -C "$t/forge/git/acme/jeryu-tool.git" rev-parse "main^{tree}")"
auth_blob="$(git -C "$t/forge/git/acme/jeryu-tool.git" rev-parse "main:tool-manifest.toml")"
auth_sha="$(manifest 1.7.6 | sha256sum | cut -d' ' -f1)"

# A dependent repository per case: put files, snap a commit, gather evidence between two commits.
D=""
dep() { D="$t/dep-$1"; git init -q -b main "$D"; }
put() { mkdir -p "$(dirname "$D/$1")"; cat >"$D/$1"; }
snap() { git -C "$D" add -A; git -C "$D" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; git -C "$D" rev-parse HEAD; }
policy() { printf '[audit]\nminimum_score = 85\nrequired_tool_version = "%s"\n' "$1"; }
evidence() { # base head -> review dir
  local o; o="$(mktemp -d "$t/out-XXXXXX")"; : >"$t/api.log"
  governed_version_evidence "$D/.git" "$1" "$2" "$o" acme "${budget:-200000}"; echo "$o"
}
field() { jq -r ".$2" "$1/governance/authority.json"; }

# 1. The one-line bump a generated scalar is: the protected manifest, the renderer sources that own
# it, and identities computed from the fetched objects, not from anything the change says.
dep bump; policy 1.7.5 | put agent/audit-policy.toml; b="$(snap base)"
policy 1.7.6 | put agent/audit-policy.toml; h="$(snap bump)"
o="$(evidence "$b" "$h")"
[ "$(field "$o" status)" = authority-verified ] && [ "$(field "$o" verified)" = true ] || fail "status: $(cat "$o/governance/authority.json")"
[ "$(field "$o" authority_repo)" = acme/jeryu-tool ] && [ "$(field "$o" authority_branch)" = main ] \
  && [ "$(field "$o" authority_branch_kind)" = default ] || fail "authority branch: $(cat "$o/governance/authority.json")"
[ "$(field "$o" authority_commit)" = "$auth_commit" ] && [ "$(field "$o" authority_tree)" = "$auth_tree" ] \
  && [ "$(field "$o" manifest_blob)" = "$auth_blob" ] && [ "$(field "$o" manifest_sha256)" = "$auth_sha" ] \
  || fail "commit/tree/blob identities: $(cat "$o/governance/authority.json")"
[ "$(field "$o" authority_version)" = 1.7.6 ] || fail "the manifest's own [jankurai] semver"
[ "$(git hash-object "$o/governance/tool-manifest.toml")" = "$auth_blob" ] \
  && [ "$(sha256sum <"$o/governance/tool-manifest.toml" | cut -d' ' -f1)" = "$auth_sha" ] \
  || fail "the manifest bytes are the ones that commit holds"
grep -q 'renders every consumer' "$o/governance/renderer/ops/render-tool-manifest.sh" \
  && grep -q 'required_tool_version' "$o/governance/renderer/crates/jeryu-tool-control/src/render_rules.rs" \
  || fail "the renderer sources that own the scalar: $(find "$o/governance" -type f)"
[ "$(jq -r '[.renderers[].path] | sort | join(",")' "$o/governance/authority.json")" \
   = "crates/jeryu-tool-control/src/render_rules.rs,ops/render-tool-manifest.sh" ] || fail "renderers recorded"
[ "$(jq -r '.renderers[] | select(.path == "ops/render-tool-manifest.sh") | .sha256' "$o/governance/authority.json")" \
   = "$(sha256sum <"$o/governance/renderer/ops/render-tool-manifest.sh" | cut -d' ' -f1)" ] || fail "renderer sha256 recorded"
[ "$(jq -c '.consumers' "$o/governance/authority.json")" \
   = '[{"path":"agent/audit-policy.toml","base_value":"1.7.5","head_value":"1.7.6","verdict":"matches-authority"}]' ] \
  || fail "consumer row: $(jq -c .consumers "$o/governance/authority.json")"
grep -q "commit ${auth_commit:0:12}" "$o/governance/SUMMARY.txt" \
  && grep -q 'agent/audit-policy.toml: 1.7.5 -> 1.7.6: matches-authority' "$o/governance/SUMMARY.txt" \
  || fail "summary: $(cat "$o/governance/SUMMARY.txt")"
grep -qx '/api/v1/repos/acme%2Fjeryu-tool' "$t/api.log" && grep -qx '/api/v1/repos/acme%2Fjeryu-tool/refs' "$t/api.log" \
  || fail "forge API paths: $(cat "$t/api.log")"
ok 'a required_tool_version bump gets the protected manifest, the renderer rules and their identities'

# 2. A version the authority does not declare is reported as differing, whatever the change says --
# including a tool-manifest.toml the change commits into the consumer itself.
dep claim; policy 1.7.5 | put agent/audit-policy.toml; b="$(snap base)"
policy 9.9.9 | put agent/audit-policy.toml
manifest 9.9.9 | put tool-manifest.toml
printf 'Bumps to 9.9.9, already governed on jeryu-tool main.\n' | put NOTES.md
o="$(evidence "$b" "$(snap claim)")"
[ "$(jq -r '.consumers[0].verdict' "$o/governance/authority.json")" = DIFFERS-FROM-AUTHORITY ] \
  && [ "$(field "$o" authority_version)" = 1.7.6 ] \
  && [ "$(git hash-object "$o/governance/tool-manifest.toml")" = "$auth_blob" ] \
  || fail "a manifest copied into the consumer is not authority: $(cat "$o/governance/authority.json")"
ok 'the authority is the forge-protected manifest, not a copy or a claim the change carries'

# 3. An unprotected branch is never authority, even when it holds the version the change declares.
dep side; policy 1.7.5 | put agent/audit-policy.toml; b="$(snap base)"
policy 9.9.9 | put agent/audit-policy.toml
o="$(evidence "$b" "$(snap side)")"
[ "$(field "$o" authority_branch)" = main ] && [ "$(jq -r '.consumers[0].verdict' "$o/governance/authority.json")" = DIFFERS-FROM-AUTHORITY ] \
  || fail "the unprotected side branch was read: $(cat "$o/governance/authority.json")"
ok 'a branch the forge does not report default or protected is not authority'

# 4. No default and no protected branch: nothing is authority, and every row is unverified.
( stub_default="" stub_main_protected=false
  o="$(evidence "$b" "$(git -C "$D" rev-parse HEAD)")"
  [ "$(field "$o" status)" = authority-branch-unknown ] && [ "$(field "$o" verified)" = false ] \
    && [ "$(jq -r '.consumers[0].verdict' "$o/governance/authority.json")" = unverified ] \
    && [ ! -e "$o/governance/tool-manifest.toml" ] && [ "$(field "$o" authority_commit)" = null ] \
    || fail "no protected branch: $(cat "$o/governance/authority.json")" ) || exit 1
# A repository the forge does not have is reported, and nothing is fetched.
( governed_authority_repo=ghost
  o="$(evidence "$b" "$(git -C "$D" rev-parse HEAD)")"
  [ "$(field "$o" status)" = authority-not-on-forge ] && [ "$(jq -r '.consumers[0].verdict' "$o/governance/authority.json")" = unverified ] \
    || fail "authority not on the forge: $(cat "$o/governance/authority.json")" ) || exit 1
# No configured authority at all: the evidence says so instead of reading nothing as agreement.
( governed_authority_repo=""
  o="$(evidence "$b" "$(git -C "$D" rev-parse HEAD)")"
  [ "$(field "$o" status)" = authority-not-configured ] && [ "$(jq -r '.consumers[0].verdict' "$o/governance/authority.json")" = unverified ] \
    && [ ! -s "$t/api.log" ] || fail "unconfigured authority: $(cat "$o/governance/authority.json")" ) || exit 1
ok 'an authority that cannot be read leaves every moved scalar unverified'

# 5. A malformed or removed scalar is a row of its own, never silent agreement.
dep malformed; policy 1.7.5 | put agent/audit-policy.toml
policy 1.7.5 | put policy/default-audit-policy.toml; b="$(snap base)"
printf '[audit]\nrequired_tool_version = "latest"\n' | put agent/audit-policy.toml
printf '[audit]\nminimum_score = 85\n' | put policy/default-audit-policy.toml
o="$(evidence "$b" "$(snap malformed)")"
[ "$(jq -c '[.consumers[] | {path, base_value, head_value, verdict}] | sort_by(.path)' "$o/governance/authority.json")" \
   = '[{"path":"agent/audit-policy.toml","base_value":"1.7.5","head_value":"!invalid","verdict":"DIFFERS-FROM-AUTHORITY"},{"path":"policy/default-audit-policy.toml","base_value":"1.7.5","head_value":"!none","verdict":"DIFFERS-FROM-AUTHORITY"}]' ] \
  || fail "malformed rows: $(jq -c .consumers "$o/governance/authority.json")"
ok 'a value that is not a version, and a policy that declares none, are reported'

# 6. Nothing is written for a change that does not move the scalar.
dep quiet; policy 1.7.5 | put agent/audit-policy.toml; b="$(snap base)"
printf '[audit]\nminimum_score = 90\nrequired_tool_version = "1.7.5"\n' | put agent/audit-policy.toml
printf 'x\n' | put src/lib.rs
o="$(evidence "$b" "$(snap quiet)")"
[ ! -e "$o/governance" ] || fail "governance/ written for a change that moves no governed version: $(find "$o" -type f)"
ok 'a change that leaves the governed version alone gets no governance evidence'

# 7. An authority manifest whose own value this parser cannot read never reads as agreement, however
# the change spells its scalar: not a dropped key, not a floating string, not the same sentinel.
mkdir -p "$t/odd"
odd_authority() { # manifest-text -> bare repo the stub serves as acme/jeryu-tool
  local d="$t/odd/$1"; git init -q -b main "$d"
  printf '%s' "$2" >"$d/tool-manifest.toml"
  mkdir -p "$d/ops"; printf '#!/bin/sh\n# renders every consumer\n' >"$d/ops/render-tool-manifest.sh"
  git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -qm "$1"
  rm -rf "$t/forge/git/acme/jeryu-tool.git"; git clone -q --bare "$d" "$t/forge/git/acme/jeryu-tool.git"
}
for spec in 'no-semver:[jankurai]
tag = "v1.7.6"
' 'not-a-version:[jankurai]
semver = "latest"
'; do
  odd_authority "${spec%%:*}" "${spec#*:}"
  dep "odd-${spec%%:*}"; policy 1.7.5 | put agent/audit-policy.toml; dec="$(snap base)"
  for head in '1.7.6' 'latest'; do
    policy "$head" | put agent/audit-policy.toml
    o="$(evidence "$dec" "$(snap "head-$head")")"
    [ "$(jq -r '.consumers[0].verdict' "$o/governance/authority.json")" = AUTHORITY-VALUE-UNREADABLE ] \
      || fail "authority ${spec%%:*} with head $head: $(jq -c '.status, .authority_version, .consumers' "$o/governance/authority.json")"
  done
  # A policy that drops the key entirely, against the same unreadable authority: still not agreement.
  printf '[audit]\nminimum_score = 85\n' | put agent/audit-policy.toml
  o="$(evidence "$dec" "$(snap dropped)")"
  [ "$(field "$o" authority_version)" != 1.7.6 ] \
    && [ "$(jq -r '.consumers[0].head_value' "$o/governance/authority.json")" = '!none' ] \
    && [ "$(jq -r '.consumers[0].verdict' "$o/governance/authority.json")" = AUTHORITY-VALUE-UNREADABLE ] \
    || fail "a dropped scalar against an unreadable authority: $(jq -c '.authority_version, .consumers' "$o/governance/authority.json")"
done
# Restore the well-formed authority for the cases below.
rm -rf "$t/forge/git/acme/jeryu-tool.git"; git clone -q --bare "$t/authority" "$t/forge/git/acme/jeryu-tool.git"
ok 'a manifest that declares no readable version leaves every row unreadable, never matching'

# 8. The authority's own spellings of the governed version: the inner spacing, trailing comment and
# single quotes TOML allows are the same declaration, so a reformatted manifest still verifies.
odd_authority spelled "[ jankurai ]  # the governed auditor
semver   =  '1.7.6'
"
dep spelled; policy 1.7.5 | put agent/audit-policy.toml; b="$(snap base)"
policy 1.7.6 | put agent/audit-policy.toml
o="$(evidence "$b" "$(snap bump)")"
[ "$(field "$o" authority_version)" = 1.7.6 ] && [ "$(jq -r '.consumers[0].verdict' "$o/governance/authority.json")" = matches-authority ] \
  || fail "a reformatted manifest: $(jq -c '.status, .authority_version, .consumers' "$o/governance/authority.json")"
rm -rf "$t/forge/git/acme/jeryu-tool.git"; git clone -q --bare "$t/authority" "$t/forge/git/acme/jeryu-tool.git"
ok 'the governed version is read however TOML spells the table header and the value'

# 9. A policy path git would quote on the default listing is still read, so a move inside it cannot
# hide: a non-ASCII directory name, which `git diff --name-only` writes as "ag\303\253nt/...".
dep quoted; policy 1.7.5 | put "$(printf 'ag\303\253nt')/audit-policy.toml"; b="$(snap base)"
policy 9.9.9 | put "$(printf 'ag\303\253nt')/audit-policy.toml"; h="$(snap moved)"
[ "$(git -C "$D" diff --name-only "$b" "$h")" != "$(git -C "$D" diff -z --name-only "$b" "$h" | tr -d '\000')" ] \
  || fail "the fixture path is not one git quotes, so this case proves nothing"
o="$(evidence "$b" "$h")"
[ -e "$o/governance/authority.json" ] || fail "no governance evidence for a move inside a quoted path: $(find "$o" -type f)"
[ "$(jq -r '.consumers[0].base_value' "$o/governance/authority.json")" = 1.7.5 ] \
  && [ "$(jq -r '.consumers[0].head_value' "$o/governance/authority.json")" = 9.9.9 ] \
  && [ "$(jq -r '.consumers[0].verdict' "$o/governance/authority.json")" = DIFFERS-FROM-AUTHORITY ] \
  || fail "a move inside a quoted path: $(jq -c .consumers "$o/governance/authority.json")"
ok 'a move inside a path git quotes is read from the blobs, not dropped'

# 10. A budget too small to hold the manifest still records the identity of the whole blob.
dep tiny; policy 1.7.5 | put agent/audit-policy.toml; b="$(snap base)"
policy 1.7.6 | put agent/audit-policy.toml; h="$(snap bump)"
o="$(budget=80 evidence "$b" "$h")"
[ "$(field "$o" manifest_truncated)" = true ] && [ "$(field "$o" manifest_sha256)" = "$auth_sha" ] \
  && [ "$(field "$o" manifest_blob)" = "$auth_blob" ] && [ "$(field "$o" authority_version)" = 1.7.6 ] \
  && [ "$(wc -c <"$o/governance/tool-manifest.toml")" -le 40 ] \
  && grep -q 'was cut at' "$o/governance/SUMMARY.txt" || fail "truncated manifest: $(cat "$o/governance/authority.json")"
[ "$(jq -r '.renderers | length' "$o/governance/authority.json")" = 0 ] \
  && grep -q 'too small' "$o/governance/SUMMARY.txt" || fail "renderers skipped on a spent budget"
# Evidence that read no renderer source, or cut the manifest, is partial, never verified: the value
# agrees but the rule that writes it was not shown, and `verified` and the row both say so.
[ "$(field "$o" status)" = authority-partial ] && [ "$(field "$o" verified)" = false ] \
  && [ "$(jq -r '.consumers[0].verdict' "$o/governance/authority.json")" = matches-authority-partial ] \
  || fail "a packet with no renderer and a cut manifest: $(jq -c '.status, .verified, .consumers' "$o/governance/authority.json")"
ok 'a cut copy is still identified by the blob the authority commit holds, and is reported partial'

[ ! -e "$t/api.unexpected" ] || fail "unexpected forge API paths: $(sort -u "$t/api.unexpected")"
[ ! -e "$t/ambient-called" ] || fail "an ambient credential helper was called"
ok 'only the two forge reads this evidence makes, and no ambient credential'
