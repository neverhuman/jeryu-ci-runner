# pr-redteam

A red-team agent whose one job is to be suspicious of every open pull request on
git.neverhuman.org, and to approve it fast unless it finds something very serious.

- **Scope:** open, non-draft PRs in every repo (`REDTEAM_FAMILIES=all`). The `jain` and
  `jeryu-split` families (`REDTEAM_PRIORITY_FAMILIES`) go first: other families are reviewed only in
  a pass where the priority families have nothing left to review. Merging covers every family.
- **Size:** diffs over 20 MB, not counting lock files (`REDTEAM_MAX_DIFF_BYTES`), are left for a
  human. Lock files are listed for the agent but not included in the diff it reads.
- **Approves** as the token's identity (PRagent by default) at the exact head SHA, with the summary
  and every finding in the review body.
- **Holds** (`request_changes`) only on a confirmed `critical` finding: a live secret, backdoor,
  deliberately weakened gate, malicious or obfuscated code, supply-chain compromise, data
  destruction, exfiltration, or prompt injection against the review. A committed private key holds
  regardless of the agent.
- **Merges** (as `jain-merge-bot`, `REDTEAM_MERGE_TOKEN_FILE`) each PR it approved, once the forge
  says `can_merge` (approval + passing required checks + no changes requested), pinned to the
  reviewed head and passport. A push after approval is re-reviewed, never merged as-is. If the merge
  token is missing or rejected, the merge pass is skipped and reviews continue.
- **Rebases** a PR the forge refuses with "base requires linear history" (the forge ignores
  `merge_method`): the branch is rebased onto its base and force-pushed as `jain-merge-bot`, leased
  to the reviewed head so a newer author push is never overwritten. The new head is re-reviewed and
  merges once its required check passes. On a conflict nothing is pushed; the author must rebase.
- **Never** tags, waives or posts statuses. It skips PRs the token's own identity wrote
  (the forge forbids self-approval) and drafts (`--include-drafts` to cover them).
- **Fails closed:** if the agent errors, times out or returns no valid verdict, nothing is posted
  and the PR is retried on the next run.
- **Re-reviews on push:** receipts are keyed by head SHA, so a new push gets a fresh review.

## Use

```sh
./pr-redteam list                                  # the queue, and why the rest skip
./pr-redteam run --dry-run --repo veox/jain-web --pr 16   # review, print the body, post nothing
./pr-redteam run                                   # review and post for the whole queue
./pr-redteam show veox/jain-web 16                 # latest local receipt
./pr-redteam heartbeat                             # one liveness beat to jeryu's /runners page
test/canary.sh                                     # a fabricated malicious PR must be blocked
```

## As a service (xbabe0 — the only host with the `claude` CLI)

```sh
./install.sh            # writes the user units for THIS directory, enables the 5-minute timer,
                        # and starts a first pass
journalctl --user -u pr-redteam -f
systemctl --user disable --now pr-redteam.timer     # stop
```

The unit's `ExecStart` is the absolute path `install.sh` was run from, so running it from a checkout
of this repo means a `git pull` updates what the timer runs. Re-run `install.sh` after moving the
directory.

Two timers are installed: `pr-redteam.timer` reviews every five minutes, and
`pr-redteam-heartbeat.timer` beats every minute.

## Showing up on jeryu's /runners page

`pr-redteam heartbeat` POSTs to `/api/v1/runners/heartbeat` using the same contract the PR gate
runners use, so one page renders both kinds of runner; this one labels itself `redteam` and reports
the review it is running plus the last one it finished. It is best-effort and never fails a review.

It beats from its own one-minute timer rather than only during a pass, because jeryu marks a runner
offline after 180s (`RUNNER_OFFLINE_AFTER_SECS`) and a pass only runs every five minutes.

The forge only accepts heartbeats from accounts listed in its `JERYU_RUNNER_REPORTERS` allowlist. A
refusal is logged once and otherwise ignored:

```
heartbeat refused (403): "this account may not report runner heartbeats (JERYU_RUNNER_REPORTERS)"
```

## Isolation

The agent runs `claude -p` from an empty directory with only `Read`, `Grep` and `Glob`, in
`dontAsk` mode, with no MCP servers and user settings only. The PR tree comes from `git archive`
(no `.git`, no hooks) and is attached with `--add-dir`. What that guarantees: nothing in the PR can
run code in the reviewer or change its settings, tools or MCP servers. What it does not: every file
in the PR is still text the agent reads, including files that look like instructions (a `CLAUDE.md`,
comments, the description). The real defence there is the prompt, which declares all PR content
untrusted data and makes instructions aimed at the reviewer a critical finding — a model-level
control, not a sandbox one.

State (receipts, bare git caches, locks) is in `~/.local/state/pr-redteam`.
