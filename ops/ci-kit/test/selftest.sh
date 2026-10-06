#!/usr/bin/env bash
# Offline regression suite for the ci-kit: vendoring, drift detection and the
# shared helpers. Scratch state lives under the repo's target/ directory.
set -euo pipefail
kit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch_root="${CI_KIT_SCRATCH:-${PWD}/target/ci-kit-selftest}"
mkdir -p "${scratch_root}"
work="$(mktemp -d "${scratch_root}/run.XXXXXX")"
trap 'rm -rf -- "${work:?}"' EXIT
failures=0

pass() { printf 'ok   %s\n' "$1"; }
flunk() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
expect_ok() {
  local name="$1"; shift
  if "$@" >"${work}/out" 2>&1; then pass "${name}"; else cat "${work}/out" >&2; flunk "${name}"; fi
}
expect_fail() {
  local name="$1"; shift
  if "$@" >"${work}/out" 2>&1; then flunk "${name} (unexpected success)"; else pass "${name}"; fi
}

# A private canonical kit copy we may mutate, and a fresh consumer repo.
fresh() {
  rm -rf -- "${work:?}/canon" "${work:?}/repo"
  cp -a "${kit_dir}" "${work}/canon"
  mkdir -p "${work}/repo/ops/ci"
  bash "${work}/canon/bin/vendor.sh" "${work}/repo" >/dev/null
}
verify() { bash "${work}/repo/ops/ci/kit/bin/verify.sh" "${work}/repo" "$@"; }

fresh
expect_ok "canonical kit is sealed" bash "${kit_dir}/bin/verify.sh" --sealed "${kit_dir}"
expect_ok "fresh vendored copy verifies" verify --canonical "${work}/canon"
grep -q "^version=$(<"${kit_dir}/VERSION")$" "${work}/repo/ops/ci/kit.pin" &&
  pass "pin records kit version" || flunk "pin records kit version"

fresh
printf '# local edit\n' >> "${work}/repo/ops/ci/kit/lib/jobs.sh"
expect_fail "edited vendored file is drift" verify

fresh
printf 'x\n' > "${work}/repo/ops/ci/kit/lib/extra.sh"
expect_fail "extra vendored file is drift" verify

fresh
rm -- "${work}/repo/ops/ci/kit/lib/security.sh"
expect_fail "missing vendored file is drift" verify

fresh
ln -s /etc/passwd "${work}/repo/ops/ci/kit/lib/link.sh"
expect_fail "symlink in vendored kit is rejected" verify

fresh
sed -i 's/^version=.*/version=0.0.0/' "${work}/repo/ops/ci/kit.pin"
expect_fail "pin version mismatch is drift" verify

fresh
sed -i 's/^sha256=.*/sha256='"$(printf '0%.0s' {1..64})"'/' "${work}/repo/ops/ci/kit.pin"
expect_fail "pin hash mismatch is drift" verify

fresh
rm -- "${work}/repo/ops/ci/kit.pin"
expect_fail "missing pin fails" verify

fresh
printf '# upstream change\n' >> "${work}/canon/lib/jobs.sh"
expect_fail "vendor refuses an unsealed canonical kit" bash "${work}/canon/bin/vendor.sh" "${work}/repo"
bash "${work}/canon/bin/seal.sh" >/dev/null
expect_ok "stale copy still matches its own pin" verify
expect_fail "stale copy behind canonical is drift" verify --canonical "${work}/canon"
bash "${work}/canon/bin/vendor.sh" "${work}/repo" >/dev/null
expect_ok "re-vendoring clears the drift" verify --canonical "${work}/canon"

# Shared helpers.
jobs_of() { env -u CARGO_BUILD_JOBS JERYU_CI_JOBS="$1" PATH="$2" bash -c \
  'source "$0/lib/jobs.sh" && ci_kit_resolve_jobs && echo "${JERYU_CI_JOBS}:${CARGO_BUILD_JOBS}"' "${kit_dir}"; }
mkdir -p "${work}/bin"
printf '#!/bin/sh\necho 5\n' > "${work}/bin/jeryu-ci-governor"
chmod +x "${work}/bin/jeryu-ci-governor"
[[ "$(jobs_of 3 "${PATH}")" == "3:3" ]] && pass "explicit JERYU_CI_JOBS wins" || flunk "explicit JERYU_CI_JOBS wins"
[[ "$(jobs_of '' "${work}/bin:${PATH}")" == "5:5" ]] && pass "governor sets job count" || flunk "governor sets job count"
expect_fail "non-numeric job count is rejected" jobs_of abc "${PATH}"

mkdir -p "${work}/envrepo/sub"
expect_ok "no .env passes" bash -c 'cd "$1" && source "$0/lib/security.sh" && ci_kit_forbid_env_files' "${kit_dir}" "${work}/envrepo"
touch "${work}/envrepo/sub/.env"
expect_fail ".env file fails" bash -c 'cd "$1" && source "$0/lib/security.sh" && ci_kit_forbid_env_files' "${kit_dir}" "${work}/envrepo"

# Secret scan feeds text files to gitleaks and honours skip patterns.
scan="${work}/scan"
mkdir -p "${scan}/target" "${scan}/apps/web/dist"
git -C "${scan}" init -q
printf 'keep\n' > "${scan}/a.txt"
printf 'skip\n' > "${scan}/target/b.txt"
printf 'skip\n' > "${scan}/apps/web/dist/c.txt"
printf '#!/bin/sh\ncat > "$CI_KIT_SCAN_CAPTURE"\n' > "${work}/bin/gitleaks"
chmod +x "${work}/bin/gitleaks"
CI_KIT_SCAN_CAPTURE="${work}/captured" PATH="${work}/bin:${PATH}" bash -c \
  'cd "$1" && source "$0/lib/security.sh" && ci_kit_secret_scan "apps/web/dist/*"' "${kit_dir}" "${scan}"
if grep -q '===== a.txt =====' "${work}/captured" && ! grep -q 'b.txt\|c.txt' "${work}/captured"; then
  pass "secret scan streams files and skips excluded paths"
else
  flunk "secret scan streams files and skips excluded paths"
fi

# Installation receipts. require_jankurai accepts a governed v3 receipt (a
# key-signed public release) and, for the transition, a v2 one (a hermetic
# source build); anything else binds nothing. The binary is a private stub, so
# its receipt is passed explicitly and named by its own digest.
mkdir -p "${work}/jk/bin" "${work}/jk/receipts"
printf '#!/bin/sh\necho "jankurai 1.7.2"\n' > "${work}/jk/bin/jankurai"
chmod 0755 "${work}/jk/bin/jankurai"
jk_sha="$(sha256sum "${work}/jk/bin/jankurai" | awk '{print $1}')"
jq -n --arg sha "${jk_sha}" --arg path "${work}/jk/bin/jankurai" '{
  schema:"jeryu.jankurai-installation/v3",
  source:{remote:"https://example.invalid/jankurai-audit",tag:"v1.7.2",
    commit:("1"*40),tree:("2"*40),asset:"jankurai-1.7.2-x86_64-unknown-linux-gnu.tar.gz",
    archive_sha256:("3"*64),provenance_sha256:("4"*64),family_lock_sha256:("5"*64),
    cargo_lock_sha256:("6"*64),verification:"release-key-signed"},
  signature:{scheme:"cosign-key-offline",verified:true,signer_sha256:("7"*64),
    cosign_sha256:("8"*64),transparency_log:false},
  build:{mode:"public-release-key-signed-v1",rustc:"rustc 1.97.1 (8bab26f4f 2026-07-14)",
    cargo:"cargo 1.97.1 (c980f4866 2026-06-30)",target_triple:"x86_64-unknown-linux-gnu"},
  governance:{status:"governed",
    manifest_repo:"https://git.neverhuman.org/git/jeryu/jeryu-tool.git",
    manifest_commit:("a"*40),manifest_tree:("b"*40),manifest_sha256:("c"*64),
    protected_main:true,protection_policy:"immutable-main-v1"},
  binary:{sha256:$sha,version_output:"jankurai 1.7.2"},
  installation:{path:$path,atomic:true},test_mode:false,conclusion:"success"}' \
  > "${work}/jk/v3.json"
jq '.schema = "jeryu.jankurai-installation/v2"
  | .source = {remote:"https://example.invalid/jankurai.git",commit:("1"*40),
      tag:"v1.6.11-split",tree:("2"*40),archive_sha256:("3"*64),
      cargo_lock_sha256:("4"*64),verification:"release-authoritative"}
  | del(.signature)
  | .build = {rustc:"rustc 1.95.0 (59807616e 2026-04-14)",
      cargo:"cargo 1.95.0 (f2d3ce0bd 2026-03-21)",target_triple:"x86_64-unknown-linux-gnu",
      mode:"oci-vendor-locked-offline-workspace-member-v2",
      builder_image:("rust@sha256:"+("5"*64)),context_sha256:("8"*64),
      cargo_net_offline:true,closed_vendor:true,network_none:true,read_only_root:true,
      non_root:true,capabilities_dropped:true,no_new_privileges:true,
      container_engine_path:"/usr/bin/docker",git_global_config_disabled:true,
      git_system_config_disabled:true,git_http_follow_redirects:false,
      git_terminal_prompt:false,jankurai_update_check:false,
      network_scope:"local-forge-source-plus-closed-vendor-network-none"}' \
  "${work}/jk/v3.json" > "${work}/jk/v2.json"
# receipt_case <base> <jq mutation> [expected verification]: verify the stub
# against a self-named receipt made from <base> with one change.
receipt_case() {
  local base="$1" mutation="$2" verification="${3:-}" staged digest
  staged="${work}/jk/staged.json"
  jq "${mutation}" "${work}/jk/${base}.json" > "${staged}"
  digest="$(sha256sum "${staged}" | awk '{print $1}')"
  rm -f -- "${work}"/jk/receipts/*.json
  mv -- "${staged}" "${work}/jk/receipts/${digest}.json"
  env -u JERYU_JANKURAI_ALLOW_TEST_RECEIPT -u JAIN_RELEASE_CI \
    JERYU_GOVERNED_JANKURAI_BIN="${work}/jk/bin/jankurai" \
    JERYU_JANKURAI_RECEIPT="${work}/jk/receipts/${digest}.json" \
    bash -c 'source "$0/lib/jankurai.sh" && require_jankurai &&
      [[ -z "$1" || "${JERYU_JANKURAI_VERIFICATION}" == "$1" ]]' "${kit_dir}" "${verification}"
}
expect_ok "governed v3 receipt verifies" receipt_case v3 . release-key-signed
expect_ok "transitional v2 receipt verifies" receipt_case v2 . release-authoritative
for mutation in '.signature.verified = false' 'del(.signature)' \
  '.signature.scheme = "cosign-keyless"' '.signature.signer_sha256 = "release.pub"' \
  '.source.verification = "release-authoritative"' \
  '.build.mode = "oci-vendor-locked-offline-workspace-member-v2"' \
  '.source.tag = "v1.6.11-split"' '.schema = "jeryu.jankurai-installation/v4"' \
  '.schema = "jeryu.jankurai-installation/v2"' '.binary.sha256 = ("0"*64)' \
  '.installation.path = "/elsewhere/jankurai"' '.governance.protected_main = false' \
  '.test_mode = true'; do
  expect_fail "v3 receipt refused: ${mutation}" receipt_case v3 "${mutation}"
done
for mutation in '.build.closed_vendor = false' '.source.verification = "release-key-signed"' \
  '.schema = "jeryu.jankurai-installation/v3"' '.binary.sha256 = ("0"*64)'; do
  expect_fail "v2 receipt refused: ${mutation}" receipt_case v2 "${mutation}"
done
expect_fail "receipt not named by its digest is refused" env \
  JERYU_GOVERNED_JANKURAI_BIN="${work}/jk/bin/jankurai" JERYU_JANKURAI_RECEIPT="${work}/jk/v3.json" \
  bash -c 'source "$0/lib/jankurai.sh" && require_jankurai' "${kit_dir}"

if (( failures > 0 )); then
  printf 'ci-kit selftest: %d failure(s)\n' "${failures}" >&2
  exit 1
fi
printf 'ci-kit selftest ok\n'
