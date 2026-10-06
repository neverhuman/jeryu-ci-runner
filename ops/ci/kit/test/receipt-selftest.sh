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

# Run receipt.sh functions in a subshell with a controller-like environment. The key path and
# owner can only be redirected through the explicit test-only flag.
lib() {
  # shellcheck disable=SC2016 # The child shell expands its own positional parameters.
  env NH_RECEIPT_SIGNING="${MODE:-required}" NH_RECEIPT_ALLOW_TEST_KEY=1 \
    NH_RECEIPT_TEST_KEY="${KEY:-${work}/signing.key}" NH_RECEIPT_TEST_KEY_OWNER="$(id -u)" \
    NH_INSTANCE=xbabe2-lan-1-20261006000000-123 NH_HOST=xbabe2 \
    NH_OS_LABEL=ubuntu24 NH_UBUNTU_VERSION=24.04 NH_IMAGE_RECEIPT="${work}/image.json" \
    NH_QUALIFICATION_RECEIPT="${work}/qual.json" NH_JOB="${work}/job" \
    bash -c 'set -euo pipefail; source "$0/receipt.sh"; eval "$1"' "${ga}" "$1"
}
# Without the flag (or with any value but 1) the environment cannot move the key or its owner.
prod_paths() {
  # shellcheck disable=SC2016 # The child shell expands its own variables.
  env "$@" NH_RECEIPT_KEY="${work}/signing.key" NH_RECEIPT_KEY_OWNER="$(id -u)" \
    NH_RECEIPT_TEST_KEY="${work}/signing.key" NH_RECEIPT_TEST_KEY_OWNER="$(id -u)" bash -c \
    'source "$0/receipt.sh"; [[ $NH_RECEIPT_KEY == /etc/neverhuman-actions/receipt-signing.key && $NH_RECEIPT_KEY_OWNER == 0 ]]' "${ga}"
}
expect_ok "env cannot override the key path or owner without the test flag" prod_paths -u NH_RECEIPT_ALLOW_TEST_KEY
expect_ok "a test flag other than 1 is ignored" prod_paths NH_RECEIPT_ALLOW_TEST_KEY=yes
# shellcheck disable=SC2016 # The child shell expands its own positional parameters.
expect_fail "controllers reject the test flag" env NH_RECEIPT_ALLOW_TEST_KEY=1 NH_RECEIPT_TEST_KEY=x NH_RECEIPT_TEST_KEY_OWNER=0 \
  bash -c 'source "$0/receipt.sh"; nh_receipt_refuse_test_override' "${ga}"
# shellcheck disable=SC2016 # The child shell expands its own positional parameters.
expect_ok "controllers run without the test flag" env -u NH_RECEIPT_ALLOW_TEST_KEY \
  bash -c 'source "$0/receipt.sh"; nh_receipt_refuse_test_override' "${ga}"
for controller in launch.sh receipt-keygen.sh; do
  expect_ok "${controller} rejects the test flag" grep -qx 'nh_receipt_refuse_test_override' "${ga}/${controller}"
done
expect_fail "the key-type check never prints private key text" grep -Eq -- '-noout -text($| )' "${ga}/receipt.sh"
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
# Pinned key hygiene: OpenSSL 3.5 accepts a private key under -pubin, so the verifier refuses
# private material itself, plus anything that is not exactly one ed25519 PEM public key.
openssl pkey -in "${work}/ec.key" -pubout -out "${work}/ec.pub" 2>/dev/null
cat "${work}/signing.pub" "${work}/signing.key" > "${work}/pub-and-private.pem"
cat "${work}/signing.pub" "${work}/other.pub" > "${work}/two-pubs.pem"
mkdir -p "${work}/privdir"; cp "${work}/signing.key" "${work}/privdir/xbabe2.pub"
ln -s "${work}/signing.pub" "${work}/link.pub"
pv() { RUNNER_NAME=xbabe2-lan-1-20261006000000-123 bash "${ga}/verify-receipt.sh" --receipt "$r" --boot-window 0 --now "$((issued + 30))" "$@"; }
expect_fail "a private key pinned as --pubkey is refused" pv --pubkey "${work}/signing.key"
expect_fail "a private key published as <host>.pub is refused" pv --pubkey-dir "${work}/privdir"
expect_fail "a pinned file carrying private material after a public key is refused" pv --pubkey "${work}/pub-and-private.pem"
expect_fail "a pinned file with two keys is refused" pv --pubkey "${work}/two-pubs.pem"
expect_fail "a non-ed25519 pinned key is refused" pv --pubkey "${work}/ec.pub"
expect_fail "a symlinked pinned key is refused" pv --pubkey "${work}/link.pub"
pv --pubkey "${work}/signing.key" > /dev/null 2> "${work}/err" || true
if grep -q 'private key material' "${work}/err"; then pass "private pinned key is refused by name"; else flunk "private pinned key is refused by name"; fi

# Strict numeric options and bounded inputs.
pvu() { pv --pubkey "${work}/signing.pub" "$@" >/dev/null 2>&1; }
expect_usage() { # <name> <args...>: the verifier must exit 2 (usage), not 0 or 1
  local name=$1 rc=0; shift
  pvu "$@" || rc=$?
  if [[ $rc == 2 ]]; then pass "${name}"; else flunk "${name} (exit ${rc})"; fi
}
expect_usage "leading-zero numbers are usage errors" --max-age 0100
expect_usage "over-long numbers are usage errors" --max-age 1234567890123
expect_usage "signed numbers are usage errors" --now -5
cp "$r" "${work}/longsig.json"; { cat "$r.sig"; printf 'x'; } > "${work}/longsig.json.sig"
expect_fail "a signature that is not 64 bytes is refused" bash "${ga}/verify-receipt.sh" --receipt "${work}/longsig.json" --pubkey "${work}/signing.pub" --runner-name xbabe2-lan-1-20261006000000-123 --boot-window 0
head -c 70000 /dev/zero | tr '\0' ' ' > "${work}/huge.json"; cp "$r.sig" "${work}/huge.json.sig"
expect_fail "an oversized receipt is refused" bash "${ga}/verify-receipt.sh" --receipt "${work}/huge.json" --pubkey "${work}/signing.pub" --runner-name xbabe2-lan-1-20261006000000-123 --boot-window 0

# Single private snapshot: verification runs on 0600 copies in a private temp dir that the
# trap removes on success and on refusal.
mkdir -p "${work}/tmp"
TMPDIR="${work}/tmp" expect_ok "verifies from the private copy" pv --pubkey "${work}/signing.pub"
TMPDIR="${work}/tmp" expect_fail "refusal still verifies only the copy" pv --pubkey "${work}/other.pub"
if [[ -z "$(ls -A "${work}/tmp")" ]]; then pass "private snapshot is removed"; else flunk "private snapshot is removed"; fi

# The published key directory may hold only README.md and public *.pub keys.
keys_clean() { # [dir]
  local f dir=${1:-${ga}/receipt-keys}
  for f in "${dir}"/* "${dir}"/.[!.]*; do
    [[ -e $f || -L $f ]] || continue
    case ${f##*/} in
      README.md) ;;
      *.pub) [[ -f $f && ! -L $f ]] && ! grep -q 'PRIVATE KEY' "$f" &&
               [[ $(head -n1 "$f") == '-----BEGIN PUBLIC KEY-----' ]] || return 1 ;;
      *) return 1 ;;
    esac
  done
  ! grep -rqs 'PRIVATE KEY' "${dir}"
}
expect_ok "receipt-keys holds no private key material or *.key files" keys_clean
mkdir -p "${work}/badkeys"
cp "${work}/signing.pub" "${work}/badkeys/xbabe2.pub"
expect_ok "a public key directory passes the hygiene check" keys_clean "${work}/badkeys"
cp "${work}/signing.key" "${work}/badkeys/xbabe3.key"
expect_fail "a *.key file under receipt-keys is caught" keys_clean "${work}/badkeys"
rm -- "${work}/badkeys/xbabe3.key"; cp "${work}/signing.key" "${work}/badkeys/xbabe3.pub"
expect_fail "a private key named *.pub under receipt-keys is caught" keys_clean "${work}/badkeys"

if (( failures > 0 )); then
  printf 'receipt selftest: %d failure(s)\n' "${failures}" >&2
  exit 1
fi
printf 'receipt selftest ok\n'
