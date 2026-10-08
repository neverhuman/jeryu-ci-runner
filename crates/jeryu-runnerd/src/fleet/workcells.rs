//! The fleet is the authority for work-cell claim epochs: every claim entry
//! point here first syncs the ledger's fence from the node registry, so a
//! claim is admitted only at the epoch the registry issued to an active node.

use jeryu_runner_core::error::RunnerResult;
use jeryu_runner_registry::NodeState;

use super::*;
use crate::warm_pool::{ClaimedCell, SessionClaim, WarmPool};
use crate::workcell::{
    FrozenCiSnapshot, HoldFailedTreeRequest, StartupSync, WorkcellClaimRequest, WorkcellLease,
    WorkcellManager, WorkcellResult,
};

impl RunnerFleet {
    /// Epoch a work-cell claim must carry for each runner right now: the
    /// registry's current epoch of every active node. A node that is
    /// registering, draining or reaped dead takes no new work cell, and a
    /// re-registered node's earlier epochs are gone, so neither appears here.
    pub fn claimable_runner_epochs(&self) -> BTreeMap<String, u64> {
        self.registry
            .nodes
            .values()
            .filter(|node| node.state == NodeState::Active)
            .map(|node| (node.node_id.clone(), node.epoch))
            .collect()
    }

    /// Claim a work cell from `ledger` for one runner, fenced on the epoch
    /// this fleet issued it.
    pub fn claim_workcell(
        &self,
        ledger: &mut WorkcellManager,
        request: WorkcellClaimRequest,
    ) -> WorkcellResult<WorkcellLease> {
        ledger.sync_runner_epochs(self.claimable_runner_epochs());
        ledger.claim(request)
    }

    /// Hold a failed tree in a fresh cell, fenced like [`Self::claim_workcell`].
    pub fn hold_failed_tree(
        &self,
        ledger: &mut WorkcellManager,
        request: HoldFailedTreeRequest,
    ) -> WorkcellResult<WorkcellLease> {
        ledger.sync_runner_epochs(self.claimable_runner_epochs());
        ledger.hold_failed_tree(request)
    }

    /// Repair from a frozen snapshot, fenced on the snapshot runner's current
    /// lifetime: a snapshot kept past that lifetime cannot mint a repair cell.
    pub fn repair_workcell(
        &self,
        ledger: &mut WorkcellManager,
        snapshot: &FrozenCiSnapshot,
        startup: StartupSync,
    ) -> WorkcellResult<WorkcellLease> {
        ledger.sync_runner_epochs(self.claimable_runner_epochs());
        ledger.repair_from_snapshot(snapshot, startup)
    }

    /// Claim a warm container cell for one agent session, fenced like
    /// [`Self::claim_workcell`].
    pub fn claim_warm_cell(
        &self,
        pool: &mut WarmPool,
        claim: SessionClaim,
    ) -> RunnerResult<ClaimedCell> {
        pool.sync_runner_epochs(self.claimable_runner_epochs());
        pool.claim(claim)
    }
}
