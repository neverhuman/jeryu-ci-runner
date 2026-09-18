# pr-redteam

Review pull requests on `git.neverhuman.org` at their exact head. Confirmed high or
critical security/correctness findings block. An explicit block verdict always
holds; failed processes, incomplete output and contradictory approvals publish
nothing. Findings and terminal attempt receipts remain available for review.

The existing separate merger owns acceptance and landing. This controller never
merges, rebases, pushes, tags, waives checks or posts required statuses. It does
not read a merger credential. Installation stages inactive units; it does not
authorize or start automated review.

## Qualification

`bash test/required.sh` runs offline verdict, binary-payload, credential-transport,
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

The model runs from an empty working directory with Read/Grep/Glob, no MCP
servers, and user settings only. PR contents are an exact-head Git archive with
no `.git` or hooks. The prompt treats source, descriptions and repository
instructions as untrusted data. These controls are not evidence of sealed
execution or protection against every model prompt injection. The live service
owner must qualify its actual filesystem, credential and tool boundaries.
