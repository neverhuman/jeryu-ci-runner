#!/usr/bin/env bash
# Exercise the production retention block against live and unpublished journals.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
runner=${1:-$script_dir/pr-gate-runner.sh}
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export HOME_DIR=$fixture KEEP_RUNS=200
mkdir -p "$fixture/attempts" "$fixture/claim-locks" "$fixture/logs"
active=acme-active-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
unpublished=acme-unpublished-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
for key in "$active" "$unpublished"; do
    mkdir -p "$fixture/attempts/$key/attempt"
    printf 'retained process output\n' > "$fixture/attempts/$key/attempt/build.log"
done
printf '{"terminal":false,"recovery_required":null}\n' \
    > "$fixture/attempts/$active/attempt/receipt.json"
printf '{"terminal":true,"outcome":"success","publication":{"required_status":false},"recovery_required":"publication denied"}\n' \
    > "$fixture/attempts/$unpublished/attempt/receipt.json"
exec 6>"$fixture/claim-locks/$active.lock"
flock -n 6
touch -d '2000-01-01 UTC' "$fixture/attempts/$active" "$fixture/attempts/$unpublished"
# Enough newer completed keys to evict both obligations under the default limit.
for sequence in $(seq 1 201); do
    printf -v key 'acme-finished-%040x' "$sequence"
    mkdir -p "$fixture/attempts/$key"
done
sed -n '/^# Attempt evidence is retained/,/^\[\[ "\$state" == success \]\]/p' "$runner" \
    | sed '$d' > "$fixture/retention.sh"
[[ -s $fixture/retention.sh ]] || { echo 'production retention block not found' >&2; exit 1; }
bash -euo pipefail "$fixture/retention.sh"
for key in "$active" "$unpublished"; do
    [[ -s $fixture/attempts/$key/attempt/receipt.json && -s $fixture/attempts/$key/attempt/build.log ]] || {
        printf 'retention erased a live or unpublished recovery obligation: %s\n' "$key" >&2
        exit 1
    }
done
echo 'PASS: live and unpublished journals survive more than 200 newer keys'
