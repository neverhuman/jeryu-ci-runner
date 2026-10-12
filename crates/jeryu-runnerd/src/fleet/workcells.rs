//! The fleet is the authority for work-cell claim epochs: every claim entry
//! point here first syncs the ledger's fence from the node registry, so a
//! fresh claim is admitted only at the epoch the registry issued to an active
//! node, and in-flight work (hold, repair) also at a draining node's epoch.

use jeryu_runner_core::error::RunnerResult;
use jeryu_runner_registry::NodeState;

use super::*;
use crate::warm_pool::{ClaimedCell, SessionClaim, WarmPool};
use crate::workcell::{
    AdmittedRunner, FrozenCiSnapshot, HoldFailedTreeRequest, RunnerAdmission, StartupSync,
    WorkcellClaimRequest, WorkcellLease, WorkcellManager, WorkcellResult,
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

    /// The work-cell fence for every runner lifetime the registry still
    /// admits: active nodes for any claim, draining nodes for in-flight work
    /// only (the registry documents that a draining node's in-flight work may
    /// finish). A registering node has no in-flight work yet, and a reaped
    /// dead node or a re-registered node's earlier epochs are not listed, so
    /// they stay fenced.
    pub fn admitted_runner_epochs(&self) -> BTreeMap<String, AdmittedRunner> {
        self.registry
            .nodes
            .values()
            .filter_map(|node| {
                let admission = match node.state {
                    NodeState::Active => RunnerAdmission::Active,
                    NodeState::Draining => RunnerAdmission::Draining,
                    NodeState::Registering | NodeState::Dead => return None,
                };
                Some((
                    node.node_id.clone(),
                    AdmittedRunner {
                        epoch: node.epoch,
                        admission,
                    },
                ))
            })
            .collect()
    }

    /// Claim a work cell from `ledger` for one runner, fenced on the epoch
    /// this fleet issued it.
    pub fn claim_workcell(
        &self,
        ledger: &mut WorkcellManager,
        request: WorkcellClaimRequest,
    ) -> WorkcellResult<WorkcellLease> {
        ledger.sync_runner_fence(self.admitted_runner_epochs());
        ledger.claim(request)
    }

    /// Hold a failed tree in a fresh cell for in-flight work, fenced on the
    /// runner's current epoch; unlike [`Self::claim_workcell`] a draining
    /// runner is admitted, since its in-flight work may still finish.
    pub fn hold_failed_tree(
        &self,
        ledger: &mut WorkcellManager,
        request: HoldFailedTreeRequest,
    ) -> WorkcellResult<WorkcellLease> {
        ledger.sync_runner_fence(self.admitted_runner_epochs());
        ledger.hold_failed_tree(request)
    }

    /// Repair from a frozen snapshot, fenced on the snapshot runner's current
    /// lifetime (active or draining): a snapshot kept past that lifetime
    /// cannot mint a repair cell.
    pub fn repair_workcell(
        &self,
        ledger: &mut WorkcellManager,
        snapshot: &FrozenCiSnapshot,
        startup: StartupSync,
    ) -> WorkcellResult<WorkcellLease> {
        ledger.sync_runner_fence(self.admitted_runner_epochs());
        ledger.repair_from_snapshot(snapshot, startup)
    }

    /// Claim a warm container cell for one agent session, fenced like
    /// [`Self::claim_workcell`].
    pub fn claim_warm_cell(
        &self,
        pool: &mut WarmPool,
        claim: SessionClaim,
    ) -> RunnerResult<ClaimedCell> {
        pool.sync_runner_fence(self.admitted_runner_epochs());
        pool.claim(claim)
    }
}
