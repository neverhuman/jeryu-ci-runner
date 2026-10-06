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

# Signed lan-ci guest receipt (github-actions/receipt.sh, verify-receipt.sh).
expect_ok "signed guest receipt suite" bash "${kit_dir}/test/receipt-selftest.sh"

if (( failures > 0 )); then
  printf 'ci-kit selftest: %d failure(s)\n' "${failures}" >&2
  exit 1
fi
printf 'ci-kit selftest ok\n'
