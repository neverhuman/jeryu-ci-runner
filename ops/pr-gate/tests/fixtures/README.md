# Deployed merge-queue contract

Captured 2026-11-01T03:28:42Z from `GET https://git.jeryu.ai/api/v1/repos/root%2Fjankurai/merge-queue?per_page=500&page=1`.
The JSON file is the complete unmodified response. Deployed forge:
`60da213c7cd1eb8d1459e5b1ceda252616b5de9d` (deployment 219).

Producer authority: `crates/jeryu-api/src/web/merge_queue.rs::build_on` in
that commit (lines 355-379):

```rust
let queue_sha = git.replay(parent, &entry.pr_head_sha, committed_after)?;
git.update_ref(&entry.queue_ref, &queue_sha)?;
entry.base_sha = parent.to_string();
entry.queue_sha = queue_sha.clone();
```

The stacked entry 22 records `after=29` and `base_sha` equal to entry 29's
`queue_sha`, distinct from the branch tip recorded by entry 29. The consumer
regression pins this relation, preserves the captured paging envelope and
substitutes local fixture Git identities for an offline replay. It exercises
the production encoded-repository route and envelope parser. It does not
replace post-install live governed proof acceptance.

## Authoritative implementations this fixture is read against

All in jeryu-deploy at `60da213c7cd1eb8d1459e5b1ceda252616b5de9d` (the forge's
own `main` at capture time), browsable on this installation's forge host
`https://git.neverhuman.org/jeryu/jeryu-deploy`:

- Route: `crates/jeryu-api/src/web.rs` registers
  `("/api/v1/repos/:id/merge-queue", get(merge_queue::list_repo))`. `list_repo`
  lists one repository's whole queue (every state, no filter), answering
  `{entries, total, page}`, and is the only listing carrying `gate_started_at`.
- Query keys: `QueuePageQuery::KEYS = ["limit", "per_page", "page"]` in
  `crates/jeryu-api/src/web/merge_queue.rs`; `web/strict_query.rs` answers any
  other key with `invalid_query` at `422`. The global
  `/api/v1/merge-queue` listing (`list_all`) is a different contract: it takes
  `state` and defaults to `building`.
- Replay parent: `merge_queue.rs::build_on` sets `entry.base_sha` to the commit
  it replayed onto — the queue commit of the entry below it in the stack, or
  the base tip for the bottom entry.
- Audit base: `crates/jeryu-api/src/ci_bridge/audit_queue.rs::plan_push_audit`
  tickets a `refs/queue/<base>/<n>` head against
  `merge-base refs/heads/<base> <queue sha>`, i.e. the stack's fork with the
  base branch — neither the moved branch tip nor the entry's replay parent.
  `merge_queue.rs::schedule_audit` dispatches through
  `ci_bridge::queue_head_audit` with the queue ref and its queue SHA.

`ops/pr-gate/tests/test-pr-gate-audit.sh` consumes each of these: the recorded
envelope, the per-repository route served with the real strict query keys and
paging (one entry per page, so a multi-entry stack is assembled only by
following `page.has_more`), and the dispatched audit base computed with the
forge's own `merge-base` expression while `main` is ahead of the stack. These
are consumer contract regressions against a fixture forge; they are not a live
governed audit.
