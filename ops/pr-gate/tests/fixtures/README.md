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
