#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
source ops/ci/proof_guards.sh
fixture="$(mktemp -d)"
trap 'rm -r -- "$fixture"' EXIT
# Execute the history guard with a depth-1 Git model. Fetch failures must
# propagate, and refreshing main must happen only after deepening succeeds.
git() {
  printf '%s\n' "$*" >> "$fixture/calls"
  case "$*" in
    'rev-parse --is-shallow-repository') echo true ;;
    'fetch --quiet --no-tags --unshallow origin main') return "$fetch_status" ;;
    'fetch --quiet --no-tags origin +refs/heads/main:refs/remotes/origin/main') return 0 ;;
    *) return 1 ;;
  esac
}
fetch_status=0
proof_require_history
[[ "$(sed -n '2p' "$fixture/calls")" == 'fetch --quiet --no-tags --unshallow origin main' ]]
[[ "$(sed -n '3p' "$fixture/calls")" == 'fetch --quiet --no-tags origin +refs/heads/main:refs/remotes/origin/main' ]]
fetch_status=1
if proof_require_history; then echo 'accepted a failed history fetch' >&2; exit 1; fi
unset -f git
printf '%s\n' '{"schema_version":"1.0.0","status":"complete","liability_score":4,"required_proof_lanes":[],"rollback_cutover_notes":["restore"]}' > "$fixture/base"
cp "$fixture/base" "$fixture/head"
proof_require_migration "$fixture/base" "$fixture/head"
for filter in '.liability_score=5' '.status="partial"' 'del(.liability_score)' '.liability_score=-1' '.rollback_cutover_notes=[]'; do
  jq "$filter" "$fixture/base" > "$fixture/head"
  if proof_require_migration "$fixture/base" "$fixture/head"; then
    printf 'accepted migration regression: %s\n' "$filter" >&2; exit 1
  fi
done
jq '.status="partial"' "$fixture/base" > "$fixture/bad-base"
if proof_require_migration "$fixture/bad-base" "$fixture/base"; then
  echo 'accepted incomplete baseline analysis' >&2; exit 1
fi
grep -qx 'bash ops/ci/proof_evidence.sh' ops/ci/pr-ci.sh
printf 'proof guards ok\n'
