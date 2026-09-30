# pr-redteam

Review pull requests on `git.neverhuman.org` at their exact head. Confirmed high or
critical security/correctness findings block. An explicit block verdict always
holds; failed processes, incomplete output and contradictory approvals publish
nothing. Findings and terminal attempt receipts remain available for review.

Where the base branch requires `jankurai/proof`, the quality gate comes first: a
head whose proof fails, has not run, or failed to score is held with that reason
before any agent budget is spent, and nothing here can approve it. Repositories
outside the gate's rollout are unaffected — their proof is reported, not
required. `ops/ci/jankurai-gate.sh` is the same verdict, run locally before the
pull request exists.

The existing separate merger owns acceptance and landing. This controller never
merges, rebases, pushes, tags, waives checks or posts required statuses. It does
not read a merger credential. Installation stages inactive units; it does not
authorize or start automated review.

## Qualification

`bash test/required.sh` runs offline quality-gate, verdict, binary-payload, credential-transport,
publication/recovery and installation checks. The actual repository required lane
runs this suite. Tests use local fixture repositories, dummy credentials and
stand-in model/forge processes. They cover malformed and failed model results,
publication refusal, restart, duplicate dispatch, worker loss and changed heads.

`test/canary.sh` is a separate paid live-model qualification for the service owner.
It requires the exact pinned CLI and selected model. Offline source qualification
does not establish the live model's accuracy, sandbox confinement, or service
activation approval.

## Commands

```sh
./pr-redteam list
./pr-redteam run --dry-run --repo veox/jain-web --pr 16
./pr-redteam run --repo veox/jain-web --pr 16
./pr-redteam show veox/jain-web 16
./pr-redteam heartbeat
```

The reviewer skips its own authored PRs, drafts unless explicitly included, and
successfully posted reviews at the current head with matching controller, prompt,
schema, model, CLI executable and version inputs. Each changed head needs a new
review. The forge receives the exact expected head and can reject publication
if it moved while the model was running. Rejected publication remains retryable.

`JERYU_TOKEN_FILE` selects the existing approval credential by path. API calls
require `https://git.neverhuman.org`, an owned mode0600 nonsymlink regular token
file and a valid bearer value. The bearer travels through curl configuration
stdin, with curlrc disabled, and is absent from curl argv. This transport guard
is separate from model/process credential confinement.

State lives in `REDTEAM_STATE` (default `~/.local/state/pr-redteam`). The per-PR
lock excludes concurrent reviews. Receipts record admitted attempts before model
execution; a killed worker leaves a visible pending claim. The next holder
archives it as interrupted before retrying. Terminal attempts remain under
`attempts/`, latest receipts under `receipts/`, and current work is removed when
an attempt terminates normally or recovers. Failed attempts never count as an
approval. Operators should investigate pending claims when no worker owns them.

## Installation and service ownership

`./install.sh` stages four user units and reloads their definitions. It refuses
to replace active or enabled units. The existing service owner must explicitly
stop/disable an earlier installation, qualify the selected source/model/CLI, and
separately authorize activation. The script never starts or enables a timer.

The units reference this source directory by absolute path. Treat any later
source update as a service change requiring its owner's custody and qualification.
The reviewer timer invokes only review publication; the separate merger remains
outside this controller. Heartbeats report liveness through Jeryu's existing
runner-reporting allowlist. An authorization refusal is logged, not bypassed.

## Review isolation

The pinned CLI runs from an empty directory with `--restricted --safe-mode`, an
explicit Read/Grep/Glob tool set and no MCP servers or customizations. Restricted
mode confines file tools to the empty working directory and exact PR review
archive. The model process receives only declared CLI authentication/runtime
variables; reviewer/merger paths and arbitrary service secrets are removed.
OAuth/provider authentication remains the existing service owner's responsibility.
The shipped unit contains no merger credential path.

Before a verdict can be printed, stored as a review receipt, or published, the
controller decodes its JSON strings and refuses the current reviewer bearer and
common encoded forms. Unsafe raw output is removed without echoing it. This is
an additional publication guard, not proof against every possible encoding or a
claim of OS-level isolation. Exact CLI behavior is owner-qualified before service
activation. A source merge does not establish sealed execution.

The CLI2.1.276 version/help readback confirms these flags; the official
[CLI reference](https://code.claude.com/docs/en/cli-reference) documents restricted
mode from2.1.248 and safe mode. PR text is still untrusted input to the model;
correctness/security qualification must include the actual model and host.
