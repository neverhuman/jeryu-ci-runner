#!/usr/bin/env bash
# Exercise the production locked-crate prefetch with a recording cargo: which lockfiles it checks, that
# an online fetch never runs where a PR's .cargo/config.toml would be read, and that a lock naming a
# host outside crates.io, the gated owner paths on the governed forge and the configured family
# sources (PR_GATE_LOCK_SOURCES) is never fetched online, while a configured loopback forge and a
# lockfile mixing a gated owner's canonical forge path with its publishing mirror are.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
runner=${1:-$script_dir/pr-gate-runner.sh}
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
awk "/^prefetch='exec 6/,/^done'\$/" "$runner" >"$fixture/prefetch.sh"
[[ -s "$fixture/prefetch.sh" ]]
# shellcheck source=/dev/null
source "$fixture/prefetch.sh"
: "${prefetch:?}"
# The runner's own translation of the governed forge configuration into the prefetch's
# allowed-source pattern: the configured mirror prefixes plus each gated owner's canonical path.
# shellcheck source=ops/pr-gate/bin/pr-gate-config.sh
source "$script_dir/pr-gate-config.sh"
LOCK_SOURCES_ERE="$(pr_gate_lock_sources_ere https://forge.example.test/ \
  "git+http://127.0.0.1:8787/git/gate-a/ git+https://mirror.example.test/gate-a/" gate-a acme)"
: "${LOCK_SOURCES_ERE:?}"

repo() { # name lockpath source-url
  local dir="$fixture/tree/$1"
  mkdir -p "$dir/$(dirname "$2")"
  [[ -d "$dir/.git" ]] || git init -q --initial-branch=main "$dir"
  printf '[[package]]\nname = "x"\nversion = "1.0.0"\nsource = "%s"\n# %s/%s\n' "$3" "$1" "$2" >"$dir/$2"
  printf '[package]\nname = "p"\nversion = "0.1.0"\n' >"$dir/$(dirname "$2")/Cargo.toml"
  git -C "$dir" add -A
}
crates=registry+https://github.com/rust-lang/crates.io-index
repo pr Cargo.lock "$crates"
repo pr nested/tool/Cargo.lock "$crates"
repo pr vendor/dep/Cargo.lock "$crates"
repo sibling Cargo.lock "$crates"
repo sibling crates/deep/Cargo.lock "$crates"
repo evil Cargo.lock "registry+https://evil.example.invalid/index"
repo forge Cargo.lock "git+http://127.0.0.1:8787/git/gate-a/acme-domain.git?tag=v1#3ae83ce17bb57f5f8dd52f087991ff59bda5afbc"
repo hosted Cargo.lock "git+https://forge.example.test/git/acme/acme-domain.git#3ae83ce17bb57f5f8dd52f087991ff59bda5afbc"
# The incident this guards: one lockfile holding the canonical forge path of a gated owner and that
# family's declared publishing mirror. Before the canonical path was derived from the forge
# configuration, the canonical row skipped the whole lockfile and the mirror crate stayed unfetched,
# so the offline required lane failed on it.
repo canonical Cargo.lock "git+https://forge.example.test/git/gate-a/tools-kernel.git?tag=v1#3ae83ce17bb57f5f8dd52f087991ff59bda5afbc"
printf '\n[[package]]\nname = "y"\nversion = "1.0.0"\nsource = "git+https://mirror.example.test/gate-a/tools-dedup.git?tag=ci-8bc3c59#8bc3c59acd0f570ca41880a8a4ec9915feed609d"\n' \
  >>"$fixture/tree/canonical/Cargo.lock"
git -C "$fixture/tree/canonical" add -A
repo foreignowner Cargo.lock "git+https://forge.example.test/git/other/tools-kernel.git?tag=v1#3ae83ce17bb57f5f8dd52f087991ff59bda5afbc"
repo credentialed Cargo.lock "git+https://bot:t0ken@forge.example.test/git/gate-a/tools-kernel.git?tag=v1#3ae83ce17bb57f5f8dd52f087991ff59bda5afbc"
repo loopback Cargo.lock "git+http://127.0.0.1:8080/git/gate-a/acme-domain.git#3ae83ce17bb57f5f8dd52f087991ff59bda5afbc"
repo lookalike Cargo.lock "git+http://127.0.0.1:8787/git/other/acme-domain.git#3ae83ce17bb57f5f8dd52f087991ff59bda5afbc"
repo dotted Cargo.lock "git+https://forgeXexample.test/git/acme/acme-domain.git#3ae83ce17bb57f5f8dd52f087991ff59bda5afbc"
repo suffixed Cargo.lock "git+https://forge.example.test.evil.invalid/git/acme/acme-domain.git#3ae83ce17bb57f5f8dd52f087991ff59bda5afbc"
mkdir -p "$fixture/tree/pr/.cargo"
printf '[source.crates-io]\nreplace-with = "evil"\n' >"$fixture/tree/pr/.cargo/config.toml"
cp "$fixture/tree/pr/Cargo.lock" "$fixture/tree/pr/nested/copy.lock.src"   # same bytes elsewhere: see dedupe
mkdir -p "$fixture/tree/pr/again" && cp "$fixture/tree/pr/Cargo.lock" "$fixture/tree/pr/again/Cargo.lock"
cp "$fixture/tree/pr/Cargo.toml" "$fixture/tree/pr/again/Cargo.toml"
git -C "$fixture/tree/pr" add -A

# A cargo that records every call and reports every lockfile as missing a registry crate offline.
mkdir -p "$fixture/bin"
cat >"$fixture/bin/cargo" <<SH
#!/usr/bin/env bash
printf '%s|%s\n' "\$PWD" "\$*" >>"$fixture/calls"
if [[ " \$* " == *" --offline "* ]]; then echo 'error: no matching package named \`x\` found' >&2; exit 101; fi
exit 0
SH
chmod +x "$fixture/bin/cargo"

PATH="$fixture/bin:$PATH" bash -c "$prefetch" pr-gate-prefetch "$fixture/tree" pr "$LOCK_SOURCES_ERE" >"$fixture/out" 2>&1

offline_dirs=$(grep -- '--offline' "$fixture/calls" | cut -d'|' -f1 | sed "s#$fixture/tree/##" | sort)
expected=$(printf '%s\n' canonical credentialed dotted evil foreignowner forge hosted lookalike loopback pr pr/nested/tool sibling suffixed | sort)
[[ "$offline_dirs" == "$expected" ]] || {
  printf 'checked offline:\n%s\nexpected:\n%s\n' "$offline_dirs" "$expected" >&2; exit 1; }
printf 'PASS scope: every lockfile of the PR repo, root lockfile of siblings, no vendored crates, each distinct lock once\n'

while IFS='|' read -r cwd args; do
  [[ "$args" == *--offline* ]] && continue
  [[ "$cwd" != "$fixture/tree"* ]] || { printf 'online fetch ran inside the tree (%s): a PR config would be read\n' "$cwd" >&2; exit 1; }
  [[ "$args" == *"--manifest-path $fixture/tree/"* ]] || { printf 'online fetch without --manifest-path: %s\n' "$args" >&2; exit 1; }
done <"$fixture/calls"
grep -v -- '--offline' "$fixture/calls" | grep -q "manifest-path $fixture/tree/pr/Cargo.toml" \
  || { printf 'the PR lockfile was not fetched online\n' >&2; exit 1; }
printf 'PASS online fetch runs outside the tree with --manifest-path, so a PR .cargo/config.toml is not read\n'

! grep -v -- '--offline' "$fixture/calls" | grep -q "tree/evil" \
  || { printf 'a lock naming an arbitrary host was fetched online\n' >&2; exit 1; }
grep -q '^skipped evil/Cargo.lock' "$fixture/out" || { printf 'the skip was not reported\n' >&2; cat "$fixture/out" >&2; exit 1; }
printf 'PASS a lock with a source outside crates.io and the family forge is never fetched online\n'

for skipped in loopback lookalike dotted suffixed foreignowner credentialed; do
  ! grep -v -- '--offline' "$fixture/calls" | grep -q "tree/$skipped/" \
    || { printf 'a source off the configured prefixes (%s) was fetched online\n' "$skipped" >&2; exit 1; }
  grep -q "^skipped $skipped/Cargo.lock" "$fixture/out" || { printf '%s was not skipped\n' "$skipped" >&2; exit 1; }
done
for fetched in forge hosted canonical; do
  grep -v -- '--offline' "$fixture/calls" | grep -q "manifest-path $fixture/tree/$fetched/Cargo.toml" \
    || { printf 'a lock on a configured source (%s) was not fetched online\n' "$fetched" >&2; cat "$fixture/out" >&2; exit 1; }
done
printf 'PASS configured and canonical-forge sources are fetched; another loopback port or path, a dot-wildcard lookalike, a suffixed host, another owner on the forge or a credentialed URL is not\n'

# The pattern itself: the forge URL and the configured prefixes, nothing wider.
for admitted in "git+https://forge.example.test/git/gate-a/k.git" "git+https://forge.example.test/git/acme/k.git" \
  "git+https://mirror.example.test/gate-a/k.git" "git+http://127.0.0.1:8787/git/gate-a/k.git"; do
  grep -qE "^($LOCK_SOURCES_ERE)" <<<"$admitted" || { printf 'the allowed-source pattern rejects %s\n' "$admitted" >&2; exit 1; }
done
for refused in "git+https://forge.example.test/git/other/k.git" "git+https://forge.example.test/k.git" \
  "git+https://bot:t0ken@forge.example.test/git/gate-a/k.git" "git+https://mirror.example.test/other/k.git" \
  "git+ssh://forge.example.test/git/gate-a/k.git"; do
  ! grep -qE "^($LOCK_SOURCES_ERE)" <<<"$refused" || { printf 'the allowed-source pattern admits %s\n' "$refused" >&2; exit 1; }
done
pr_gate_lock_sources_ere https://forge.example.test 'git+https://bot:t0ken@forge.example.test/' gate-a >/dev/null 2>&1 \
  && { printf 'a configured prefix carrying credentials was accepted\n' >&2; exit 1; } || true
pr_gate_lock_sources_ere 'https://bot:t0ken@forge.example.test' '' gate-a >/dev/null 2>&1 \
  && { printf 'a forge URL carrying credentials was accepted\n' >&2; exit 1; } || true
printf 'PASS the pattern admits each gated owner on the governed forge and the configured mirror only, and refuses credentials in configuration\n'
