#!/usr/bin/env bash
# Exercise pr-gate-config.sh: the site file is data, never shell, and the caller's environment wins.
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
fx=$(mktemp -d)
trap 'rm -rf -- "$fx"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat >"$fx/pr-gate.env" <<EOF
# a comment, then a blank line

PR_GATE_FORGE_URL=https://forge.example.test
  GATE_RUNNER_OWNERS="acme gate-a"
GATE_RUNNER_IDENTITY='runner-bot'
JERYU_TOKEN_FILE=~/.config/jeryu/credentials/gate.token
PR_GATE_CHECKOUT_ROOTS=acme=src/acme gate-a=~/elsewhere/gate-a
PR_GATE_PRIMARY_OWNER=acme
PR_GATE_LOCK_SOURCES=\$(touch $fx/executed)
GATE_INSTALL_MIRROR=\`touch $fx/executed\`
PATH=/nonexistent
LD_PRELOAD=/nonexistent.so
PR_GATE_CONFIG=/nonexistent
not a setting
PR_GATE_CODE_REPO=from-file/repo
EOF

probe() { # prints the settings a fresh shell ends up with
  HOME=/home/gate PR_GATE_CONFIG="$fx/pr-gate.env" bash -c '
    source "$1/pr-gate-config.sh"
    pr_gate_load_config
    for k in PR_GATE_FORGE_URL GATE_RUNNER_OWNERS GATE_RUNNER_IDENTITY JERYU_TOKEN_FILE PR_GATE_CHECKOUT_ROOTS \
      PR_GATE_PRIMARY_OWNER PR_GATE_LOCK_SOURCES GATE_INSTALL_MIRROR PR_GATE_CODE_REPO PR_GATE_CONFIG_FILE; do
      printf "%s=[%s]\n" "$k" "${!k-unset}"
    done
    printf "PATH-kept=%s\n" "$([[ "$PATH" != /nonexistent ]] && echo yes || echo no)"
    printf "LD_PRELOAD=[%s]\n" "${LD_PRELOAD-unset}"' _ "$script_dir"
}
out=$(probe)
expect() { grep -qxF -- "$1" <<<"$out" || fail "expected $1 in:"$'\n'"$out"; }
expect 'PR_GATE_FORGE_URL=[https://forge.example.test]'
expect 'GATE_RUNNER_OWNERS=[acme gate-a]'
expect 'GATE_RUNNER_IDENTITY=[runner-bot]'
expect 'JERYU_TOKEN_FILE=[/home/gate/.config/jeryu/credentials/gate.token]'
expect 'PR_GATE_CHECKOUT_ROOTS=[acme=src/acme gate-a=~/elsewhere/gate-a]'
expect 'PR_GATE_PRIMARY_OWNER=[acme]'
expect "PR_GATE_LOCK_SOURCES=[\$(touch $fx/executed)]"
expect "GATE_INSTALL_MIRROR=[\`touch $fx/executed\`]"
expect 'PR_GATE_CODE_REPO=[from-file/repo]'
expect "PR_GATE_CONFIG_FILE=[$fx/pr-gate.env]"
expect 'PATH-kept=yes'
expect 'LD_PRELOAD=[unset]'
[[ ! -e "$fx/executed" ]] || fail 'a value was executed as shell'
printf 'PASS KEY=VALUE data: quotes stripped, ~/ expanded, nothing executed, foreign keys ignored\n'

out=$(GATE_RUNNER_OWNERS=gate-a PR_GATE_CODE_REPO='' probe)
expect 'GATE_RUNNER_OWNERS=[gate-a]'
expect 'PR_GATE_CODE_REPO=[]'
expect 'GATE_RUNNER_IDENTITY=[runner-bot]'
printf 'PASS a value the caller set wins over the file, even an empty one\n'

out=$(HOME=/home/gate PR_GATE_CONFIG="$fx/missing.env" bash -c 'source "$1/pr-gate-config.sh"; pr_gate_load_config
  printf "PR_GATE_FORGE_URL=[%s]\n" "${PR_GATE_FORGE_URL-unset}"' _ "$script_dir")
expect 'PR_GATE_FORGE_URL=[unset]'
printf 'PASS a missing site file loads nothing and is not an error by itself\n'

# shellcheck source=ops/pr-gate/bin/pr-gate-config.sh
source "$script_dir/pr-gate-config.sh"
HOME=/home/gate
[[ "$(pr_gate_path /abs/path)" == /abs/path ]] || fail 'absolute path'
# shellcheck disable=SC2088  # the literal "~/" is the input under test
[[ "$(pr_gate_path '~/x/y')" == /home/gate/x/y ]] || fail 'home path'
[[ "$(pr_gate_path rel/z)" == /home/gate/rel/z ]] || fail 'relative path'
[[ -z "$(pr_gate_path '')" ]] || fail 'empty path'
[[ "$(pr_gate_lookup 'acme=src/acme gate-a=x' gate-a)" == x ]] || fail 'lookup'
! pr_gate_lookup 'acme=src/acme' gate || fail 'lookup prefix matched'
! pr_gate_lookup 'acme' acme || fail 'lookup of a bare word'
cd "$fx"; touch acme-ops
pr_gate_listed 'acme/* other' acme/web || fail 'glob listed'
pr_gate_listed 'x y' z y || fail 'any name listed'
! pr_gate_listed '*' || fail 'no names'
! pr_gate_listed 'acme-*' acme || fail 'glob expanded against the working directory'
! pr_gate_listed '' acme || fail 'empty list'
printf 'PASS path, lookup and list helpers\n'
