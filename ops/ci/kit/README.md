# jeryu ci-kit

Shared CI helpers for the jeryu split family, owned here and vendored into each
repository as a pinned copy (the same model as the Jankurai pin).

- `lib/jankurai.sh`: `require_tool`, `require_jankurai`, `jankurai`. The caller
  exports its generated `JERYU_JANKURAI_*` pin block first.
- `lib/security.sh`: `ci_kit_secret_scan [skip-glob...]`, `ci_kit_forbid_env_files`.
- `lib/jobs.sh`: `ci_kit_resolve_jobs` (governor-driven `JERYU_CI_JOBS`).

Repository-specific lanes (fleet score floor, extra security tools, the lanes
a `pr-ci.sh` runs) stay in each repository's `ops/ci/`.

## Versioning

`VERSION` is the kit version; the content hash is the sha256 of
`MANIFEST.sha256`. After changing any kit file, bump `VERSION` and run
`bash ops/ci-kit/bin/seal.sh`. `ops/ci/check.sh` fails if the kit is unsealed.

## Vendoring

    bash ops/ci-kit/bin/vendor.sh <target-repo-root>

writes `<target>/ops/ci/kit/` and `<target>/ops/ci/kit.pin`. The consumer's
gate runs `bash ops/ci/kit/bin/verify.sh .`, which fails when the copy differs
from its pin. Pass `--canonical <path-to-jeryu-ci-runner>/ops/ci-kit` to also
fail when the pin is behind the canonical kit. Never edit a vendored copy; fix
the kit here and re-vendor.

`bash ops/ci-kit/test/selftest.sh` is the offline regression suite.
