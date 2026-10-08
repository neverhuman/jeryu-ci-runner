//! Workcell manager lifecycle implementation.

use super::*;

impl WorkcellManager {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_warm_pool(warm_cells: usize) -> Self {
        let mut manager = Self::new();
        for _ in 0..warm_cells {
            manager.spawn_ready_cell();
        }
        manager
    }

    /// Builder: the token values, from the daemon's configuration, that a
    /// frozen or held capsule must never carry.
    #[must_use]
    pub fn with_forbidden_token_values(mut self, values: Vec<String>) -> Self {
        self.forbidden_token_values = values;
        self
    }

    /// Builder: the roots, from the daemon's configuration, that an export may
    /// be written under. Without any, every export is refused.
    #[must_use]
    pub fn with_export_destination_roots(mut self, roots: Vec<PathBuf>) -> Self {
        self.export_destination_roots = roots;
        self
    }

    pub fn ready_count(&self) -> usize {
        self.ready_queue.len()
    }

    pub fn workcell(&self, workcell_id: &str) -> Option<&WorkcellLease> {
        self.cells.get(workcell_id)
    }

    pub fn workcells(&self) -> Vec<WorkcellLease> {
        let mut leases: Vec<_> = self.cells.values().cloned().collect();
        leases.sort_by(|a, b| a.workcell_id.cmp(&b.workcell_id));
        leases
    }

    /// Replace the claim fence with the runner epochs the daemon issued. This
    /// is the fence's only writer: the fleet calls it from its registry (see
    /// [`crate::RunnerFleet::claim_workcell`]) before every claim, so a claim's
    /// own `runner_epoch` is checked but never trusted. Replacing the whole
    /// table also prunes it: a runner the registry no longer lists as active
    /// (reaped, draining, never registered) loses its entry and is fenced.
    pub fn sync_runner_epochs(&mut self, issued: impl IntoIterator<Item = (String, u64)>) {
        self.runner_epochs = issued.into_iter().collect();
    }

    pub fn claim(&mut self, request: WorkcellClaimRequest) -> WorkcellResult<WorkcellLease> {
        // Fence a stale runner lifetime before a cell is consumed, so a late
        // claim from a previous epoch neither takes a warm cell nor mints one.
        self.require_claim_epoch(&request.runner_id, request.runner_epoch)?;
        self.claim_unfenced(request)
    }

    /// Hand one cell to `request` without checking the runner-level claim
    /// fence. Private: [`Self::claim`] and [`Self::repair_from_snapshot`] each
    /// fence the runner's real epoch before calling it.
    fn claim_unfenced(&mut self, request: WorkcellClaimRequest) -> WorkcellResult<WorkcellLease> {
        let warm_hit = !self.ready_queue.is_empty();
        let workcell_id = match self.ready_queue.pop_front() {
            Some(workcell_id) => workcell_id,
            None => self.mint_cell(),
        };
        let outcome = {
            let lease = self
                .cells
                .get_mut(&workcell_id)
                .expect("ready queue and lease table stay in sync");
            lease.apply_claim(&request);
            lease.apply_startup(&request.startup);
            match &request.startup {
                StartupSync::Rebased { .. } => Ok(()),
                StartupSync::Failed {
                    main_ref, reason, ..
                } => Err(WorkcellError::startup_rebase_failed(format!(
                    "workcell {} could not rebase onto {}: {}",
                    lease.workcell_id, main_ref, reason
                ))),
            }
        };

        // Keep the warm pool at a steady depth as soon as a warm cell is
        // consumed. A claim served by a freshly minted cell drew from an empty
        // pool, so there is no depth to restore.
        if warm_hit {
            self.spawn_ready_cell();
        }

        let lease = self
            .cells
            .get(&workcell_id)
            .expect("ready queue and lease table stay in sync")
            .clone();
        match outcome {
            Ok(()) => Ok(lease),
            Err(err) => Err(err),
        }
    }

    /// Queue one warm cell and return its id so the warm pool can pair it with a
    /// detached `jeryu.workcell=<id>` container. The id matches the container
    /// label, which is what the reaper compares against the live ledger.
    pub fn warm_one(&mut self) -> String {
        self.spawn_ready_cell()
    }

    /// True while `workcell_id` is still queued as a ready, never-claimed cell.
    /// The warm pool asks this after a refused claim: a cell that is still
    /// queued keeps its container, any other container is no longer backed.
    pub(crate) fn is_ready_queued(&self, workcell_id: &str) -> bool {
        self.ready_queue.iter().any(|id| id == workcell_id)
            && self
                .cells
                .get(workcell_id)
                .is_some_and(|cell| matches!(cell.state, WorkcellState::Ready))
    }

    /// Claim the ready cell with this exact id — the warm pool has already paired
    /// it with a detached container labeled `jeryu.workcell=<id>`. Unlike
    /// [`WorkcellManager::claim`], the ready queue entry is consumed without
    /// minting a replacement, because the warm pool owns container refill.
    pub fn claim_ready(
        &mut self,
        workcell_id: &str,
        request: WorkcellClaimRequest,
    ) -> WorkcellResult<WorkcellLease> {
        // Every refusal below happens before the ready queue entry is consumed
        // and before the lease is touched, so a denied claim leaves the cell
        // exactly as it was for the claim that is allowed to win. The runner
        // fence goes first, so a fenced lifetime is always reported as fenced
        // whatever state the cell is in.
        self.require_claim_epoch(&request.runner_id, request.runner_epoch)?;
        let state = self
            .cells
            .get(workcell_id)
            .ok_or_else(|| WorkcellError::claim_denied(format!("unknown warm cell {workcell_id}")))?
            .state;
        if !matches!(state, WorkcellState::Ready) {
            return Err(WorkcellError::claim_denied(format!(
                "warm cell {workcell_id} is {} and only a ready cell can be claimed",
                state.as_str()
            )));
        }
        let queued = self
            .ready_queue
            .iter()
            .position(|id| id == workcell_id)
            .ok_or_else(|| {
                WorkcellError::claim_denied(format!(
                    "warm cell {workcell_id} is not in the ready queue"
                ))
            })?;

        self.ready_queue.remove(queued);
        let cell = self
            .cells
            .get_mut(workcell_id)
            .expect("ready queue and lease table stay in sync");
        cell.apply_claim(&request);
        cell.apply_startup(&request.startup);
        let outcome = match &request.startup {
            StartupSync::Rebased { .. } => Ok(()),
            StartupSync::Failed {
                main_ref, reason, ..
            } => Err(WorkcellError::startup_rebase_failed(format!(
                "workcell {workcell_id} could not rebase onto {main_ref}: {reason}"
            ))),
        };
        let lease = cell.clone();
        outcome.map(|()| lease)
    }

    pub fn repair_from_snapshot(
        &mut self,
        snapshot: &FrozenCiSnapshot,
        startup: StartupSync,
    ) -> WorkcellResult<WorkcellLease> {
        // A snapshot may only be repaired by the runner lifetime that froze it:
        // one kept past that lifetime is fenced like any other stale claim.
        self.require_claim_epoch(&snapshot.runner_id, snapshot.runner_epoch)?;
        let request = WorkcellClaimRequest {
            agent_id: snapshot.branch_policy.agent_id.clone(),
            workspace_root: snapshot.workspace_root.clone(),
            repo_roots: snapshot.repo_roots.clone(),
            branch_budget: snapshot.branch_policy.max_branches,
            runner_id: snapshot.runner_id.clone(),
            runner_epoch: snapshot.runner_epoch.saturating_add(1),
            git_status_summary: snapshot.git_status_summary.clone(),
            ci_snapshot_age_ms: Some(snapshot.snapshot_age_ms),
            startup,
        };
        // The bumped epoch is this repair cell's own fencing token, not a new
        // runner lifetime: the runner was fenced on its real epoch above, and
        // the bump must neither be checked against nor move the runner fence.
        let mut lease = self.claim_unfenced(request)?;
        let workcell_id = lease.workcell_id.clone();
        let cell = self
            .cells
            .get_mut(&workcell_id)
            .expect("claimed workcell must stay live");
        cell.state = WorkcellState::Held;
        cell.frozen_snapshot = Some(snapshot.clone());
        cell.branch_policy = snapshot.branch_policy.clone();
        cell.git_status_summary = snapshot.git_status_summary.clone();
        cell.ci_snapshot_age_ms = Some(snapshot.snapshot_age_ms);
        cell.heartbeat_healthy = snapshot.heartbeat_healthy;
        cell.failed_run_id = Some(snapshot.failed_run_id.clone());
        cell.failed_receipt_id = Some(snapshot.failed_receipt_id.clone());
        cell.allowed_paths = snapshot.allowed_paths.clone();
        cell.failure_log_digest = Some(snapshot.failure_log_digest.clone());
        lease = cell.clone();
        Ok(lease)
    }

    pub fn hold_failed_tree(
        &mut self,
        request: HoldFailedTreeRequest,
    ) -> WorkcellResult<WorkcellLease> {
        let HoldFailedTreeRequest {
            claim,
            ci_run_id,
            failed_run_id,
            failed_receipt_id,
            failure_log_digest,
        } = request;
        Self::guard_capsule(
            &claim.git_status_summary,
            &failure_log_digest,
            &self.forbidden_token_values,
        )?;
        let mut lease = self.claim(claim)?;
        let workcell_id = lease.workcell_id.clone();
        let cell = self
            .cells
            .get_mut(&workcell_id)
            .expect("claimed workcell must stay live");
        cell.state = WorkcellState::Held;
        cell.failed_run_id = Some(failed_run_id.clone());
        cell.failed_receipt_id = Some(failed_receipt_id.clone());
        cell.failure_log_digest = Some(failure_log_digest.clone());
        cell.allowed_paths = cell
            .repo_roots
            .iter()
            .cloned()
            .chain(std::iter::once(cell.workspace_root.clone()))
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let snapshot_source = cell.clone();
        cell.frozen_snapshot = Some(FrozenCiSnapshot::from_workcell(
            ci_run_id,
            failed_run_id,
            failed_receipt_id,
            &snapshot_source,
            failure_log_digest,
            snapshot_source.ci_snapshot_age_ms.unwrap_or_default(),
        ));
        lease = cell.clone();
        Ok(lease)
    }

    pub fn begin_live_repair(
        &mut self,
        workcell_id: &str,
        runner_epoch: u64,
    ) -> WorkcellResult<WorkcellLease> {
        let cell = self.cells.get_mut(workcell_id).ok_or_else(|| {
            WorkcellError::epoch_fenced(format!("unknown workcell {workcell_id}"))
        })?;
        Self::require_epoch(cell, runner_epoch)?;
        if !matches!(cell.state, WorkcellState::Held) {
            return Err(WorkcellError::repair_state_denied(format!(
                "workcell {workcell_id} must be held before repair can start"
            )));
        }
        cell.state = WorkcellState::Repairing;
        Ok(cell.clone())
    }

    pub fn export_repair_branch(
        &mut self,
        workcell_id: &str,
        runner_epoch: u64,
        branch_suffix: impl Into<String>,
    ) -> WorkcellResult<String> {
        let cell = self.cells.get_mut(workcell_id).ok_or_else(|| {
            WorkcellError::epoch_fenced(format!("unknown workcell {workcell_id}"))
        })?;
        Self::require_epoch(cell, runner_epoch)?;
        if !matches!(cell.state, WorkcellState::Held | WorkcellState::Repairing) {
            return Err(WorkcellError::repair_state_denied(format!(
                "workcell {workcell_id} must be held or repairing before export"
            )));
        }
        cell.branch_policy.open_branch(branch_suffix)
    }

    /// Export workspace `paths` of a held or repairing workcell to
    /// `destination`. The sources must sit inside the lease's repo roots and
    /// carry no host credential material; the destination must sit inside a
    /// configured export root and not pass through a symlink. Nothing is
    /// written here: the caller writes only after this returns `Ok`.
    pub fn export_workspace(
        &self,
        workcell_id: &str,
        runner_epoch: u64,
        paths: &[PathBuf],
        destination: &Path,
    ) -> WorkcellResult<()> {
        let cell = self.cells.get(workcell_id).ok_or_else(|| {
            WorkcellError::epoch_fenced(format!("unknown workcell {workcell_id}"))
        })?;
        Self::require_epoch(cell, runner_epoch)?;
        if !matches!(cell.state, WorkcellState::Held | WorkcellState::Repairing) {
            return Err(WorkcellError::repair_state_denied(format!(
                "workcell {workcell_id} must be held or repairing before export"
            )));
        }
        validate_export_paths(paths, &cell.repo_roots)?;
        validate_export_destination(destination, &self.export_destination_roots)
    }

    pub fn heartbeat(
        &mut self,
        workcell_id: &str,
        runner_epoch: u64,
        heartbeat_healthy: bool,
    ) -> WorkcellResult<()> {
        let cell = self.cells.get_mut(workcell_id).ok_or_else(|| {
            WorkcellError::epoch_fenced(format!("unknown workcell {workcell_id}"))
        })?;
        Self::require_epoch(cell, runner_epoch)?;
        if !matches!(
            cell.state,
            WorkcellState::Claimed | WorkcellState::Held | WorkcellState::Repairing
        ) {
            return Err(WorkcellError::claim_denied(format!(
                "workcell {workcell_id} is not active"
            )));
        }
        cell.heartbeat_healthy = heartbeat_healthy;
        Ok(())
    }

    pub fn release(&mut self, workcell_id: &str, runner_epoch: u64) -> WorkcellResult<()> {
        let cell = self.cells.get_mut(workcell_id).ok_or_else(|| {
            WorkcellError::epoch_fenced(format!("unknown workcell {workcell_id}"))
        })?;
        Self::require_epoch(cell, runner_epoch)?;
        cell.state = WorkcellState::Released;
        cell.heartbeat_healthy = false;
        Ok(())
    }

    pub fn block(
        &mut self,
        workcell_id: &str,
        runner_epoch: u64,
        reason: impl Into<String>,
    ) -> WorkcellResult<()> {
        let cell = self.cells.get_mut(workcell_id).ok_or_else(|| {
            WorkcellError::epoch_fenced(format!("unknown workcell {workcell_id}"))
        })?;
        Self::require_epoch(cell, runner_epoch)?;
        cell.mark_blocked(reason);
        Ok(())
    }

    pub fn freeze_failed_ci_run(
        &self,
        workcell_id: &str,
        runner_epoch: u64,
        request: FreezeFailedCiRunRequest,
    ) -> WorkcellResult<FrozenCiSnapshot> {
        let cell = self.cells.get(workcell_id).ok_or_else(|| {
            WorkcellError::epoch_fenced(format!("unknown workcell {workcell_id}"))
        })?;
        Self::require_epoch(cell, runner_epoch)?;
        Self::guard_capsule(
            &cell.git_status_summary,
            &request.failure_log_digest,
            &self.forbidden_token_values,
        )?;
        Ok(FrozenCiSnapshot::from_workcell(
            request.ci_run_id,
            request.failed_run_id,
            request.failed_receipt_id,
            cell,
            request.failure_log_digest,
            request.snapshot_age_ms,
        ))
    }

    /// Mint a ready cell into the lease table without queueing it. The caller
    /// owns the new id: a claim hands it straight to one agent, so it must not
    /// also sit in the ready queue where the next claim would take it.
    pub(super) fn mint_cell(&mut self) -> String {
        self.next_id = self.next_id.saturating_add(1);
        let workcell_id = format!("wc-{:04}", self.next_id);
        let lease = WorkcellLease::ready(workcell_id.clone());
        self.cells.insert(workcell_id.clone(), lease);
        workcell_id
    }

    /// Mint a ready cell and queue it for the next claim.
    fn spawn_ready_cell(&mut self) -> String {
        let workcell_id = self.mint_cell();
        self.ready_queue.push_back(workcell_id.clone());
        workcell_id
    }

    /// Refuse a claim whose epoch is not the one the daemon issued for this
    /// runner. Like the registry's `is_current_owner`, this fails closed and
    /// matches exactly: a runner with no issued epoch is fenced, a lower epoch
    /// is a lifetime the daemon moved past, and a higher one it never issued.
    fn require_claim_epoch(&self, runner_id: &str, runner_epoch: u64) -> WorkcellResult<()> {
        match self.runner_epochs.get(runner_id) {
            Some(&active) if runner_epoch == active => Ok(()),
            Some(&active) => Err(WorkcellError::epoch_fenced(format!(
                "runner {runner_id} claim fenced: epoch {runner_epoch} != active {active}"
            ))),
            None => Err(WorkcellError::epoch_fenced(format!(
                "runner {runner_id} claim fenced: the daemon issued it no active epoch"
            ))),
        }
    }

    fn require_epoch(cell: &WorkcellLease, runner_epoch: u64) -> WorkcellResult<()> {
        if cell.runner_epoch != runner_epoch {
            return Err(WorkcellError::epoch_fenced(format!(
                "workcell {} fenced: epoch {} != active {}",
                cell.workcell_id, runner_epoch, cell.runner_epoch
            )));
        }
        Ok(())
    }

    /// Refuse to freeze a capsule that carries a configured token value. The
    /// capsule is evidence that outlives the run, so a leak here is permanent.
    fn guard_capsule(
        git_status_summary: &str,
        failure_log_digest: &str,
        forbidden_token_values: &[String],
    ) -> WorkcellResult<()> {
        validate_capture_text("capsule", git_status_summary, forbidden_token_values)?;
        validate_capture_text("capsule", failure_log_digest, forbidden_token_values)
    }
}
