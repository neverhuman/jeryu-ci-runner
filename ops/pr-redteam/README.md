# pr-redteam

Review pull requests on the forge named by `JERYU_BASE` at their exact head. Confirmed high or
critical security/correctness findings block. An explicit block verdict always
holds; failed processes, incomplete output and contradictory approvals publish
nothing. Findings and terminal attempt receipts remain available for review.

Where the base branch requires `jankurai/proof`, the quality gate comes first: a
head whose proof fails or failed to score is held with that reason before any
agent budget is spent, and nothing here can approve it. A proof the forge has
queued, is running, or has not started is not a verdict on the head: that head
gets no review and no receipt, and a later pass reviews it once the proof has a
result. Repositories
outside the gate's rollout are unaffected — their proof is reported, not
required. `ops/ci/jankurai-gate.sh` is the same verdict, run locally before the
pull request exists.

pr-redteam also lands what it approved. After the review pass, every open PR
this controller approved at its current head is merged as the merger identity,
once the forge itself says it can merge: approval, required contexts green, no
changes requested. The merge is pinned to the exact reviewed head and the
forge's merge passport, so a PR pushed after approval is never landed — it is
reviewed again at its new head.

Merge eligibility is recomputed on every pass from this controller's own
receipts, independently of the "already reviewed" skip. That skip covers the
review only. A required context that fails on its first attempt and succeeds on
the gate runner's retry is therefore landed on the next pass, with no second
review; the same holds for a head that was behind its base and became
mergeable.

Branches are never rewritten. An approved PR behind a linear-history base is
handed to the forge's merge queue (`REDTEAM_QUEUE=1`, the default), which
replays and gates it without touching anybody's branch. With `REDTEAM_QUEUE=0
REDTEAM_REBASE=1` the controller will instead rebase and force-push such a
branch, leased to the reviewed head; this is off by default because the family's
no-force rule does not permit it, and an empty rebase is never pushed.

The controller never tags, waives checks or posts required statuses.
`REDTEAM_MERGE_TOKEN_FILE` selects the merger credential by path and has no
default: this source is public, so the path is site configuration. Unset or
unreadable, the review pass still runs and nothing is landed. Installation
stages inactive units; it does not authorize or start automated review or
landing.

## Qualification

`bash test/required.sh` runs offline quality-gate, draft-skip, verdict, binary-payload,
credential-transport, publication/recovery, merge-pass and installation checks. The actual repository required lane
runs this suite. Tests use local fixture repositories, dummy credentials and
stand-in model/forge processes. They cover malformed and failed model results,
publication refusal, restart, duplicate dispatch, worker loss and changed heads,
and the landing path: approve, a failing required context, that context going
green on a retry, and the merge that follows without a second review.

`test/canary.sh` is a separate paid live-model qualification for the service owner.
It requires the exact pinned CLI and selected model. Offline source qualification
does not establish the live model's accuracy, sandbox confinement, or service
activation approval.

## Commands

```sh
./pr-redteam list
./pr-redteam run --dry-run --repo acme/widget-web --pr 16
./pr-redteam run --repo acme/widget-web --pr 16
./pr-redteam show acme/widget-web 16
./pr-redteam heartbeat
./pr-redteam poke --dry-run
```

`heartbeat` sends one beat per reviewer slot: a review takes a numbered slot for
as long as it runs, so `/runners` shows `REDTEAM_JOBS` rows (`<id>`, `<id>-2` …)
instead of one row for the whole pass. `poke` runs every 30 seconds from
`pr-redteam-poke.timer` and starts `pr-redteam.service` early when a head nobody
has reviewed appears or an approval becomes landable, once per head; it never
reviews or merges itself, and the five-minute timer stays as the fallback.

The reviewer skips its own authored PRs, drafts unless explicitly included, and
successfully posted reviews at the current head with matching controller, prompt,
schema, model, CLI executable and version inputs. Each changed head needs a new
review. A PR whose base branch the forge does not have yet — the shape a new
repository is bootstrapped with, since a first push to the default branch is
refused — is recorded once per head as `base_missing` and left to a person,
rather than failing its fetch again on every pass. The forge receives the exact
expected head and can reject publication if it moved while the model was running. Rejected publication remains retryable.

A skipped draft is reported to the forge as one `pr.skipped` pipeline event per
head, so it appears on the pull request's own timeline instead of only in this
log; `list` and `--dry-run` post nothing. Marking a draft ready for review is
the author's or an admin's move:
`POST /api/v1/repos/{id}/pulls/{number}/ready`.

`JERYU_BASE` names the forge origin and `JERYU_TOKEN_FILE` selects the approval
credential by path; both are required site settings with no default, since this
source is public. `REDTEAM_MERGE_TOKEN_FILE` selects the merger credential. API
calls require a bare `https://host` origin with no port, path, credentials or
query, an owned mode0600 nonsymlink regular token file and a valid bearer
value. The bearer travels through curl configuration
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
The timer invokes a review pass and then a merge pass. `install.sh` stages all
six units (review, heartbeat and poke, each a service and a timer) and enables none. The merger credential's
path comes from the site's `~/.config/pr-redteam/merge.env`, read by the unit;
`install.sh` writes no credential and no credential path. Heartbeats report liveness through Jeryu's existing
runner-reporting allowlist. An authorization refusal is logged, not bypassed.

## Review isolation

The pinned CLI runs from an empty directory with `--restricted --safe-mode`, an
explicit Read/Grep/Glob tool set and no MCP servers or customizations. Restricted
mode confines file tools to the empty working directory and exact PR review
archive. The model process receives only declared CLI authentication/runtime
variables; reviewer/merger paths and arbitrary service secrets are removed.
OAuth/provider authentication remains the existing service owner's responsibility.
The shipped unit contains no credential and no merger credential path: it only
reads the site's environment file.

Before a verdict can be printed, stored as a review receipt, or published, the
controller decodes its JSON strings and refuses the current reviewer bearer, the
configured merger bearer, and common encoded forms. Unsafe raw output is removed without echoing it. This is
an additional publication guard, not proof against every possible encoding or a
claim of OS-level isolation. Exact CLI behavior is owner-qualified before service
activation. A source merge does not establish sealed execution.

The CLI2.1.276 version/help readback confirms these flags; the official
[CLI reference](https://code.claude.com/docs/en/cli-reference) documents restricted
mode from2.1.248 and safe mode. PR text is still untrusted input to the model;
correctness/security qualification must include the actual model and host.
