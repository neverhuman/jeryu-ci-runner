#!/usr/bin/env bash
# Exercise pr-gate-runner.sh --preflight: stale locks, pinned-tool drift, red mains; read-only.
set -euo pipefail
while read -r leaked; do unset "$leaked"; done < <(compgen -e | grep -E '^(GATE_RUNNER_|GATE_INSTALL_|JERYU_|PR_GATE_)' || true)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
fx=$(mktemp -d)
trap 'rm -rf -- "$fx"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$fx/bin" "$fx/home/tree/repo-a/.git" "$fx/home/tree-other-slot2/repo-b/.git" "$fx/home/cache" "$fx/tools"
printf 'PREFLIGHT-TOKEN-91\n' >"$fx/token"; chmod 0600 "$fx/token"
cat >"$fx/bin/curl" <<'SH'
#!/usr/bin/env bash
url=''; for a in "$@"; do case "$a" in https://*) url=$a;; esac; done
printf '%s\n' "$url" >>"$PREFLIGHT_CURL_LOG"
case "$url" in
  */branches/main) printf '{"commit":{"sha":"%s"}}\n200' "$(printf 'a%.0s' $(seq 40))";;
  */repos/acme/good/commits/*) printf '{"statuses":[{"context":"good/required","state":"failure","updated_at":"2026-01-01"},{"context":"good/required","state":"success","updated_at":"2026-02-01"}]}\n200';;
  */repos/acme/red/commits/*) printf '{"statuses":[{"context":"red/required","state":"failure"}]}\n200';;
  *) printf '{}\n404';;
esac
SH
cat >"$fx/bin/dpkg-query" <<'SH'
#!/usr/bin/env bash
case "${@: -1}" in
  poppler-utils) printf 'ii |25.03.0-5ubuntu2';;
  *) exit 1;;
esac
SH
chmod +x "$fx/bin/curl" "$fx/bin/dpkg-query"
printf '#!/bin/sh\necho pdfinfo\n' >"$fx/tools/pdfinfo"; chmod +x "$fx/tools/pdfinfo"
digest=$(sha256sum "$fx/tools/pdfinfo" | cut -c1-64)
export PREFLIGHT_CURL_LOG="$fx/curl.log" PATH="$fx/bin:$PATH"
export PR_GATE_CONFIG="$fx/none.env" PR_GATE_FORGE_URL=https://forge.example.test JERYU_TOKEN_FILE="$fx/token"
export GATE_RUNNER_HOME="$fx/home" GATE_RUNNER_TOOLS="$fx/tools" GATE_RUNNER_IDENTITY=bot GATE_RUNNER_OWNERS=acme
export GATE_RUNNER_REPOS="acme/good acme/red" PR_GATE_PINNED_TOOLS_FILE="$fx/pinned.txt"
run() { bash "$script_dir/pr-gate-runner.sh" --preflight >"$fx/out" 2>&1 && rc=0 || rc=$?; }

# a stale lock in slot 2's tree, a fresh one in slot 0's
touch -d '10 days ago' "$fx/home/tree-other-slot2/repo-b/.git/index.lock"
touch "$fx/home/tree/repo-a/.git/index.lock"
printf 'pdfinfo poppler-utils 25.03.0-5ubuntu1 %s\n' "$digest" >"$fx/pinned.txt"
run
[[ "$rc" == 1 ]] || fail "findings must exit 1, got $rc: $(cat "$fx/out")"
grep -q 'stale lock .*tree-other-slot2/repo-b/.git/index.lock' "$fx/out" || fail 'stale lock not named'
! grep -q 'stale lock .*/tree/repo-a' "$fx/out" || fail 'a fresh lock was reported'
grep -q 'pdfinfo: poppler-utils is 25.03.0-5ubuntu2, reviewed: 25.03.0-5ubuntu1' "$fx/out" || fail 'package drift not named'
grep -q 'acme/red main .*red/required is failure' "$fx/out" || fail 'red main not named'
grep -q 'ok    acme/good main .*good/required success' "$fx/out" || fail 'latest status must win'
! grep -q PREFLIGHT-TOKEN "$fx/out" "$fx/curl.log" || fail 'token leaked'
[[ -f "$fx/home/tree-other-slot2/repo-b/.git/index.lock" ]] || fail 'preflight must not remove the lock'

# clean host
rm "$fx/home/tree-other-slot2/repo-b/.git/index.lock"
printf 'pdfinfo poppler-utils 25.03.0-5ubuntu1,25.03.0-5ubuntu2 %s\n' "$digest" >"$fx/pinned.txt"
GATE_RUNNER_REPOS="acme/good" run
[[ "$rc" == 0 ]] || fail "clean host must exit 0, got $rc: $(cat "$fx/out")"

# digest drift and an unknown tool
printf 'pdfinfo poppler-utils 25.03.0-5ubuntu2 %s\nnope poppler-utils 1\n' "$(printf 'b%.0s' $(seq 64))" >"$fx/pinned.txt"
GATE_RUNNER_REPOS="acme/good" run
[[ "$rc" == 1 ]] && grep -q 'pdfinfo: .* has digest' "$fx/out" && grep -q 'nope: not found' "$fx/out" || fail 'digest drift / missing tool'

# extra arguments are refused
bash "$script_dir/pr-gate-runner.sh" --preflight --list >/dev/null 2>&1 && fail 'extra args accepted' || true
echo "pr-gate preflight: ok"
