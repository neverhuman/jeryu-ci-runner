#!/usr/bin/env bash
# The per-base forge probe (ops/pr-gate/tests/probe-forge-per-base.sh) needs a forge, two
# credentials and a scratch repository, so this suite exercises only what it decides before it
# makes a request: the arguments it refuses, and that no gate runs it.
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe="$here/probe-forge-per-base.sh"
fx=$(mktemp -d)
trap 'rm -rf -- "$fx"' EXIT
printf 'author-token\n' >"$fx/author"
printf 'runner-token\n' >"$fx/runner"

must() { local why=$1; shift; "$@" || { printf 'FAIL: %s\n' "$why" >&2; exit 1; }; }
# The probe's refusal: exit 2 and no request. A forge URL that would fail loudly if one were made
# (an address no resolver answers for) proves the refusal came first.
refuses() { # why -- args...
  local why=$1 out rc=0; shift
  out=$("$probe" "$@" 2>&1) || rc=$?
  [[ "$rc" == 2 ]] || { printf 'FAIL: %s: exit %s\n%s\n' "$why" "$rc" "$out" >&2; exit 1; }
  printf 'ok: %s\n' "$why"
}
unreachable=http://probe.invalid

must 'the probe is executable' test -x "$probe"
must 'and parses' bash -n "$probe"

refuses 'no arguments at all'
refuses 'a forge with no owner' --forge "$unreachable"
refuses 'no token files' --forge "$unreachable" --owner acme --repo probe-1
refuses 'only one token file' --forge "$unreachable" --owner acme --repo probe-1 \
  --author-token-file "$fx/author"
refuses 'an unknown argument' --forge "$unreachable" --owner acme --repo probe-1 \
  --author-token-file "$fx/author" --runner-token-file "$fx/runner" --delete-everything
refuses 'a token file it cannot read' --forge "$unreachable" --owner acme --repo probe-1 \
  --author-token-file "$fx/author" --runner-token-file "$fx/absent"
# An owner or repository name is pasted into request paths and into a git remote URL, so a name
# that is not a plain repository name is refused before either is built.
# shellcheck disable=SC2016  # literal names, never expanded
for bad in -rf 'a b' 'a/b' 'a;b' '../etc' '$(id)' '.hidden'; do
  refuses "the owner name $bad" --forge "$unreachable" --owner "$bad" --repo probe-1 \
    --author-token-file "$fx/author" --runner-token-file "$fx/runner"
  refuses "the repository name $bad" --forge "$unreachable" --owner acme --repo "$bad" \
    --author-token-file "$fx/author" --runner-token-file "$fx/runner"
done
printf 'PASS the probe refuses incomplete arguments and unusable owner/repository names\n'

# It writes to a forge and creates a repository: no gate may run it. required.sh names its suites
# one by one, and the probe is not one of them.
unlisted() { ! bash "$here/required.sh" --list | grep -q probe-forge-per-base; }
must 'the probe is not a suite of the pr-gate gate' unlisted
printf 'PASS no gate lane runs the probe\n'
