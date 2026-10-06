#!/usr/bin/env bash
# Offline regression suite for the signed lan-ci guest receipt (github-actions/receipt.sh,
# github-actions/verify-receipt.sh). Needs jq and openssl; uses throwaway keys only.
set -euo pipefail
kit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ga="${kit_dir}/github-actions"
scratch_root="${CI_KIT_SCRATCH:-${PWD}/target/ci-kit-selftest}"
mkdir -p "${scratch_root}"
work="$(mktemp -d "${scratch_root}/receipt.XXXXXX")"
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

(umask 077 && openssl genpkey -algorithm ed25519 -out "${work}/signing.key" 2>/dev/null)
openssl pkey -in "${work}/signing.key" -pubout -out "${work}/signing.pub" 2>/dev/null
(umask 077 && openssl genpkey -algorithm ed25519 -out "${work}/other.key" 2>/dev/null)
openssl pkey -in "${work}/other.key" -pubout -out "${work}/other.pub" 2>/dev/null
(umask 077 && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${work}/ec.key" 2>/dev/null)
mkdir -p "${work}/job" "${work}/keys"
cp "${work}/signing.pub" "${work}/keys/xbabe2.pub"
printf '{"phase":"image-prepared","image_sha256":"%s"}\n' "$(printf 'a%.0s' {1..64})" > "${work}/image.json"
printf '{"phase":"vm-qualified","log_sha256":"%s"}\n' "$(printf 'b%.0s' {1..64})" > "${work}/qual.json"

# Run receipt.sh functions in a subshell with a controller-like environment.
lib() {
  # shellcheck disable=SC2016 # The child shell expands its own positional parameters.
  env NH_RECEIPT_SIGNING="${MODE:-required}" NH_RECEIPT_KEY="${KEY:-${work}/signing.key}" \
    NH_RECEIPT_KEY_OWNER="$(id -u)" NH_INSTANCE=xbabe2-lan-1-20261006000000-123 NH_HOST=xbabe2 \
    NH_OS_LABEL=ubuntu24 NH_UBUNTU_VERSION=24.04 NH_IMAGE_RECEIPT="${work}/image.json" \
    NH_QUALIFICATION_RECEIPT="${work}/qual.json" NH_JOB="${work}/job" \
    bash -c 'set -euo pipefail; source "$0/receipt.sh"; eval "$1"' "${ga}" "$1"
}
# shellcheck disable=SC2016 # The child shell expands its own positional parameters.
expect_fail "signing is off by default" env -u NH_RECEIPT_SIGNING bash -c 'source "$0/receipt.sh"; nh_receipt_enabled' "${ga}"
MODE=sometimes expect_fail "unknown signing mode is refused" lib nh_receipt_enabled
expect_ok "required mode is enabled" lib nh_receipt_enabled
KEY="${work}/absent.key" expect_fail "required mode fails closed without a key" lib nh_receipt_check_key
cp "${work}/signing.key" "${work}/loose.key"; chmod 0644 "${work}/loose.key"
KEY="${work}/loose.key" expect_fail "group/world-readable key is refused" lib nh_receipt_check_key
ln -s "${work}/signing.key" "${work}/link.key"
KEY="${work}/link.key" expect_fail "symlinked key is refused" lib nh_receipt_check_key
KEY="${work}/ec.key" expect_fail "non-ed25519 key is refused" lib nh_receipt_check_key
KEY="${work}/absent.key" expect_fail "issue fails closed without a key" lib 'nh_receipt_issue 1 abc'
if [[ ! -e "${work}/job/guest-receipt.json" ]]; then pass "no receipt written without a key"; else flunk "no receipt written without a key"; fi

expect_ok "issue signs and self-verifies" lib "nh_receipt_issue 1 $(printf 'a%.0s' {1..64})"
r="${work}/job/guest-receipt.json"
if jq -e --arg img "$(printf 'a%.0s' {1..64})" '.schema == "neverhuman.lan-runner-receipt.v1" and .runner_name == .instance
    and .instance == "xbabe2-lan-1-20261006000000-123" and .host == "xbabe2" and .lane == 1 and .image_sha256 == $img
    and (.qualification_log_sha256 | test("^b{64}$")) and (.issued_at_epoch | type) == "number" and (.nonce | test("^[0-9a-f]{32}$"))' "$r" >/dev/null; then
  pass "receipt carries name, image, qualification and time"
else
  flunk "receipt carries name, image, qualification and time"
fi
issued=$(jq -r .issued_at_epoch "$r")

lib nh_receipt_cloud_files > "${work}/files.yaml"
{ printf '#cloud-config\nwrite_files:\n  - path: /etc/profile.d/x.sh\n    content: |\n      export A=1\n'; cat "${work}/files.yaml"; } > "${work}/user-data"
if python3 -c 'import yaml' 2>/dev/null; then
  parse_ok() { python3 - "${work}/user-data" "$r" "$r.sig" <<'PY'
import base64, sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
files = {f["path"]: f for f in doc["write_files"]}
assert len(files) == 3
for path, src in (("/etc/neverhuman-ci/receipt.json", sys.argv[2]), ("/etc/neverhuman-ci/receipt.json.sig", sys.argv[3])):
    f = files[path]
    assert f["encoding"] == "b64" and f["permissions"] == "0644"
    assert base64.b64decode(f["content"]) == open(src, "rb").read()
PY
  }
else
  # No PyYAML: still prove the two entries decode to the exact signed bytes, in order.
  parse_ok() {
    mapfile -t contents < <(sed -n 's/^    content: //p' "${work}/files.yaml")
    [[ ${#contents[@]} -eq 2 ]] &&
      cmp -s <(printf '%s' "${contents[0]}" | base64 -d) "$r" &&
      cmp -s <(printf '%s' "${contents[1]}" | base64 -d) "$r.sig" &&
      grep -qx '  - path: /etc/neverhuman-ci/receipt.json' "${work}/files.yaml" &&
      grep -qx '  - path: /etc/neverhuman-ci/receipt.json.sig' "${work}/files.yaml"
  }
fi
expect_ok "cloud-config entries parse and carry the exact signed bytes" parse_ok
if grep -q 'BEGIN PUBLIC KEY\|guest-receipt.pub' "${work}/user-data"; then flunk "seed must not ship a public key"; else pass "seed ships no public key"; fi

v() { bash "${ga}/verify-receipt.sh" --receipt "$r" --now "$((issued + 30))" --boot-time "$((issued + 20))" "$@"; }
RUNNER_NAME=xbabe2-lan-1-20261006000000-123 expect_ok "verifies with the pinned key" v --pubkey "${work}/signing.pub"
RUNNER_NAME=xbabe2-lan-1-20261006000000-123 expect_ok "verifies with a published key directory" v --pubkey-dir "${work}/keys"
RUNNER_NAME=xbabe2-lan-1-20261006000000-123 expect_fail "a different key is refused" v --pubkey "${work}/other.pub"
RUNNER_NAME=xbabe2-lan-2-20261006000000-999 expect_fail "another runner name is refused" v --pubkey "${work}/signing.pub"
expect_fail "empty RUNNER_NAME is refused" env -u RUNNER_NAME bash "${ga}/verify-receipt.sh" --receipt "$r" --pubkey "${work}/signing.pub" --now "$((issued + 30))" --boot-time "$((issued + 20))"
RUNNER_NAME=xbabe2-lan-1-20261006000000-123 expect_fail "a stale receipt is refused" v --pubkey "${work}/signing.pub" --max-age 10
RUNNER_NAME=xbabe2-lan-1-20261006000000-123 expect_fail "a future receipt is refused" bash "${ga}/verify-receipt.sh" --receipt "$r" --pubkey "${work}/signing.pub" --now "$((issued - 600))" --boot-window 0
RUNNER_NAME=xbabe2-lan-1-20261006000000-123 expect_fail "a guest booted long after issue is refused" bash "${ga}/verify-receipt.sh" --receipt "$r" --pubkey "${work}/signing.pub" --now "$((issued + 7200))" --boot-time "$((issued + 3600))"
RUNNER_NAME=xbabe2-lan-1-20261006000000-123 expect_fail "a guest booted before issue is refused" bash "${ga}/verify-receipt.sh" --receipt "$r" --pubkey "${work}/signing.pub" --now "$((issued + 30))" --boot-time "$((issued - 600))"
cp "$r" "${work}/tampered.json"; cp "$r.sig" "${work}/tampered.json.sig"
sed -i 's/"lane":1/"lane":2/' "${work}/tampered.json"
RUNNER_NAME=xbabe2-lan-1-20261006000000-123 expect_fail "a tampered receipt is refused" bash "${ga}/verify-receipt.sh" --receipt "${work}/tampered.json" --pubkey "${work}/signing.pub" --boot-window 0
cp "$r" "${work}/badsig.json"; head -c 64 /dev/zero > "${work}/badsig.json.sig"
RUNNER_NAME=xbabe2-lan-1-20261006000000-123 expect_fail "a forged signature is refused" bash "${ga}/verify-receipt.sh" --receipt "${work}/badsig.json" --pubkey "${work}/signing.pub" --boot-window 0
expect_fail "verifier requires a pinned key" bash "${ga}/verify-receipt.sh" --receipt "$r" --runner-name x

if (( failures > 0 )); then
  printf 'receipt selftest: %d failure(s)\n' "${failures}" >&2
  exit 1
fi
printf 'receipt selftest ok\n'
