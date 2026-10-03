#!/usr/bin/env bash
# Exercise ops/ci/sandbox-image.sh: the matrix base image is pinned by digest,
# overrides must be too, and a cached image is never pulled. Offline: docker is
# a stub recording what it was asked.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lib="${root}/ops/ci/sandbox-image.sh"
fx="$(mktemp -d)"
trap 'rm -rf -- "${fx}"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

pinned='alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc'
other='alpine:3.20@sha256:0000000000000000000000000000000000000000000000000000000000000000'

cat >"${fx}/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DOCKER_CALLS}"
if [[ "$1" == "image" && "$2" == "inspect" ]]; then
  [[ "${DOCKER_CACHED:-}" == "$3" ]]
fi
STUB
chmod +x "${fx}/docker"

probe() { # probe <env assignments...> -- prints resolved image, or "refused"
  env -u JERYU_SANDBOX_IMAGE -u IMAGE PATH="${fx}:${PATH}" "$@" \
    bash -c 'source "$0"; jeryu_sandbox_image_resolve || echo refused' "${lib}" 2>/dev/null
}

[[ "$(probe)" == "${pinned}" ]] || fail "default must be the digest pin, got $(probe)"
[[ "$(probe JERYU_SANDBOX_IMAGE="${other}")" == "${other}" ]] \
  || fail "a digest-pinned JERYU_SANDBOX_IMAGE must win"
[[ "$(probe IMAGE="${other}")" == "${other}" ]] || fail "a digest-pinned IMAGE must win"
[[ "$(probe JERYU_SANDBOX_IMAGE="${other}" IMAGE="${pinned}")" == "${other}" ]] \
  || fail "JERYU_SANDBOX_IMAGE must win over IMAGE"
for unpinned in 'alpine:3.20' 'alpine' 'alpine@sha256:abc' 'alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc-x'; do
  [[ "$(probe JERYU_SANDBOX_IMAGE="${unpinned}")" == "refused" ]] \
    || fail "tag-only override ${unpinned} must be refused"
  [[ "$(probe IMAGE="${unpinned}")" == "refused" ]] \
    || fail "tag-only IMAGE ${unpinned} must be refused"
done

# The refusal says what to do about it.
message="$(env -u IMAGE PATH="${fx}:${PATH}" JERYU_SANDBOX_IMAGE='alpine:3.20' \
  bash -c 'source "$0"; jeryu_sandbox_image_resolve' "${lib}" 2>&1 || true)"
grep -q 'must be pinned by digest' <<<"${message}" || fail "refusal must say why: ${message}"
grep -q 'JERYU_SANDBOX_IMAGE' <<<"${message}" || fail "refusal must name the override: ${message}"

# A cached image is inspected and never pulled.
calls="${fx}/warm.log"
: >"${calls}"
DOCKER_CALLS="${calls}" DOCKER_CACHED="${pinned}" PATH="${fx}:${PATH}" \
  bash -c 'source "$0"; jeryu_sandbox_image_ensure "$1"' "${lib}" "${pinned}" >/dev/null 2>&1 \
  || fail "a cached image must satisfy ensure"
grep -q "^image inspect ${pinned}$" "${calls}" || fail "ensure must inspect first: $(cat "${calls}")"
if grep -q '^pull ' "${calls}"; then fail "a warm host must not pull: $(cat "${calls}")"; fi

# A cold host pulls exactly the pinned reference, once.
calls="${fx}/cold.log"
: >"${calls}"
DOCKER_CALLS="${calls}" PATH="${fx}:${PATH}" \
  bash -c 'source "$0"; jeryu_sandbox_image_ensure "$1"' "${lib}" "${pinned}" >/dev/null 2>&1 \
  || fail "a cold host must pull"
[[ "$(grep -c "^pull ${pinned}$" "${calls}")" == "1" ]] \
  || fail "ensure must pull the pinned digest once: $(cat "${calls}")"

# The matrix consumes the shared resolution rather than carrying its own default.
grep -q 'jeryu_sandbox_image_resolve' "${root}/tests/sandbox_escape_matrix.sh" \
  || fail "the escape matrix must resolve its image through ops/ci/sandbox-image.sh"
if grep -qE 'JERYU_SANDBOX_IMAGE:-[^}]*alpine' "${root}/tests/sandbox_escape_matrix.sh"; then
  fail "the escape matrix must not keep a second image default"
fi

printf 'sandbox image pin: PASS\n'
