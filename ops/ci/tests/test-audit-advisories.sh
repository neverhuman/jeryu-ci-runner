#!/usr/bin/env bash
# Exercise the production entrypoint with overlapping database updates/reads.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/work" "$fixture/shared"
printf 'shared database\n' > "$fixture/shared/advisory"
cat > "$fixture/bin/cargo" <<'CARGO'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 5 && $1 == audit && $2 == --db && $4 == --deny && $5 == warnings ]]
[[ $3 == target/security/advisory-db.*/db ]]
mkdir "$3"
printf '%s\n' "$3" >> "$FIXTURE/paths"
: > "$3/advisory"
[[ ${AUDIT_STATUS:-0} == 0 ]] || exit "$AUDIT_STATUS"
# Both readers must reach the partially written state before either completes.
for ((i=0; i<500; i++)); do
  [[ $(wc -l < "$FIXTURE/paths") == 2 ]] && break
  sleep 0.01
done
[[ $(wc -l < "$FIXTURE/paths") == 2 ]]
printf '%s\n' "$3" > "$3/advisory"
[[ $(cat "$3/advisory") == "$3" ]]
exit "${AUDIT_STATUS:-0}"
CARGO
chmod +x "$fixture/bin/cargo"
export FIXTURE="$fixture" PATH="$fixture/bin:$PATH"
cd "$fixture/work"
bash "$root/ops/ci/audit-advisories.sh" & first=$!
bash "$root/ops/ci/audit-advisories.sh" & second=$!
wait "$first"
wait "$second"
[[ $(sort -u "$fixture/paths" | wc -l) == 2 ]]
[[ -z $(find target/security -mindepth 1 -print -quit) ]]
[[ $(cat "$fixture/shared/advisory") == 'shared database' ]]
# Parser/fetch failures propagate unchanged and also clean the private checkout.
if AUDIT_STATUS=42 bash "$root/ops/ci/audit-advisories.sh"; then
  echo 'audit failure was swallowed' >&2
  exit 1
else
  [[ $? == 42 ]]
fi
[[ -z $(find target/security -mindepth 1 -print -quit) ]]
grep -q '^bash ops/ci/audit-advisories.sh$' "$root/tools/security-lane.sh"
printf 'advisory isolation ok\n'
