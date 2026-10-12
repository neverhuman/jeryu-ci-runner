//! A work cell is claimable only from Ready, and only by a runner at the
//! epoch the fleet registry issued it: these drive the ledger and the fleet's
//! claim entry points and assert every refusal, including a concurrent double
//! claim.

use std::sync::{Arc, Barrier, Mutex};
use std::thread;

use jeryu_ci_ir::RunnerClass;
use jeryu_runnerd::workcell::FreezeFailedCiRunRequest;
use jeryu_runnerd::{
    DispatchMode, HoldFailedTreeRequest, RunnerAdmission, RunnerDaemon, RunnerFleet, StartupSync,
    WorkcellClaimRequest, WorkcellManager, WorkcellState,
};
use std::path::PathBuf;

const RUNNER: &str = "runner-anvil-3";

/// A ledger whose fence lists `RUNNER` at `epoch`, for tests of the per-cell
/// claim rules rather than of the fleet.
fn ledger_at(epoch: u64) -> WorkcellManager {
    let mut manager = WorkcellManager::new();
    manager.sync_runner_epochs([(RUNNER.to_string(), epoch)]);
    manager
}

fn daemon() -> RunnerDaemon {
    RunnerDaemon::new(
        RUNNER,
        2,
        vec![RunnerClass::NativeRustClean],
        Vec::new(),
        DispatchMode::Explain,
    )
}

/// A fleet with `RUNNER` registered, and the epoch the registry issued it.
fn fleet() -> (RunnerFleet, u64) {
    let mut fleet = RunnerFleet::new(10);
    let epoch = fleet.register(daemon(), 0);
    (fleet, epoch)
}

fn root() -> PathBuf {
    PathBuf::from("/workspace/anvil/forge")
}

fn claim_request(agent_id: &str, runner_epoch: u64) -> WorkcellClaimRequest {
    WorkcellClaimRequest {
        agent_id: agent_id.into(),
        workspace_root: root(),
        repo_roots: vec![root()],
        branch_budget: 1,
        runner_id: "runner-anvil-3".into(),
        runner_epoch,
        git_status_summary: "clean".into(),
        ci_snapshot_age_ms: Some(0),
        startup: StartupSync::Rebased {
            main_ref: "origin/main".into(),
            base_sha: "aa11bb22".into(),
            head_sha: "cc33dd44".into(),
        },
    }
}

// The second claim of the same warm cell loses: the first agent keeps the
// lease and the loser gets a claim denial naming the claimed state.
#[test]
fn a_second_claim_of_the_same_warm_cell_is_denied() {
    let mut manager = ledger_at(4);
    let workcell_id = manager.warm_one();

    let lease = manager
        .claim_ready(&workcell_id, claim_request("agent-anvil-1", 4))
        .expect("the first claim wins");
    assert_eq!(lease.state, WorkcellState::Claimed);

    let denied = manager
        .claim_ready(&workcell_id, claim_request("agent-anvil-2", 4))
        .expect_err("a claimed cell is not claimable again");
    assert_eq!(denied.reason, "workcell_claim_denied");
    assert!(
        denied.message().contains("claimed"),
        "message names the prior state: {}",
        denied.message()
    );

    let held = manager.workcell(&workcell_id).expect("lease stays live");
    assert_eq!(
        held.agent_id, "agent-anvil-1",
        "the losing claim never steals the cell"
    );
}

// A released cell is not recycled back into the ready queue, so claiming it
// again is refused on its prior state rather than silently reopened.
#[test]
fn a_released_cell_cannot_be_claimed_again() {
    let mut manager = ledger_at(6);
    let workcell_id = manager.warm_one();
    manager
        .claim_ready(&workcell_id, claim_request("agent-anvil-4", 6))
        .expect("claim succeeds");
    manager.release(&workcell_id, 6).expect("release succeeds");

    let denied = manager
        .claim_ready(&workcell_id, claim_request("agent-anvil-5", 6))
        .expect_err("a released cell is not claimable");
    assert_eq!(denied.reason, "workcell_claim_denied");
    assert!(
        denied.message().contains("released"),
        "message names the prior state: {}",
        denied.message()
    );
    assert_eq!(
        manager.workcell(&workcell_id).unwrap().state,
        WorkcellState::Released
    );
}

// An unknown id never resolves to a cell, so it cannot be claimed into one.
#[test]
fn an_unknown_cell_id_is_not_claimable() {
    let mut manager = ledger_at(1);
    let denied = manager
        .claim_ready("wc-not-minted", claim_request("agent-anvil-6", 1))
        .expect_err("an unknown id is not claimable");
    assert_eq!(denied.reason, "workcell_claim_denied");
    assert!(denied.message().contains("unknown warm cell"));
}

// The runner epoch is the fencing token: once the daemon issues epoch 9, a
// claim carrying epoch 8 belongs to a runner lifetime already moved past.
#[test]
fn a_claim_carrying_a_stale_runner_epoch_is_fenced() {
    let mut manager = ledger_at(9);
    let first = manager.warm_one();
    manager
        .claim_ready(&first, claim_request("agent-anvil-7", 9))
        .expect("the current epoch claims");

    let stale_id = manager.warm_one();
    let fenced = manager
        .claim_ready(&stale_id, claim_request("agent-anvil-8", 8))
        .expect_err("a stale epoch is fenced");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
    assert_eq!(
        manager.workcell(&stale_id).unwrap().state,
        WorkcellState::Ready,
        "the fenced claim leaves the warm cell ready for the live epoch"
    );
    assert_eq!(
        manager.ready_count(),
        1,
        "a fenced claim does not consume the ready queue entry"
    );

    // The live epoch still claims the cell the stale one failed to take.
    manager
        .claim_ready(&stale_id, claim_request("agent-anvil-9", 9))
        .expect("the live epoch still claims");
}

// The fence fails closed: a ledger the daemon never synced, or a fleet that
// never registered the runner, fences every claim before a cell is touched.
#[test]
fn a_runner_the_daemon_never_issued_an_epoch_is_fenced() {
    let mut bare = WorkcellManager::with_warm_pool(1);
    let fenced = bare
        .claim(claim_request("agent-anvil-20", 1))
        .expect_err("an unsynced ledger fences every claim");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
    assert_eq!(bare.ready_count(), 1, "no warm cell consumed");

    let empty = RunnerFleet::new(10);
    let mut ledger = WorkcellManager::with_warm_pool(1);
    let fenced = empty
        .claim_workcell(&mut ledger, claim_request("agent-anvil-21", 1))
        .expect_err("an unregistered runner is fenced");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
    assert_eq!(ledger.workcells().len(), 1, "no cell minted");
}

// The fleet's claim path is fenced on the registry's epoch, and refuses
// before it consumes a warm cell or mints a new one.
#[test]
fn the_fleet_claim_path_is_fenced_on_a_stale_epoch() {
    let (fleet, epoch) = fleet();
    let mut ledger = WorkcellManager::with_warm_pool(1);
    fleet
        .claim_workcell(&mut ledger, claim_request("agent-anvil-10", epoch))
        .expect("the issued epoch claims");
    let ready_before = ledger.ready_count();
    let cells_before = ledger.workcells().len();

    let fenced = fleet
        .claim_workcell(&mut ledger, claim_request("agent-anvil-11", epoch - 1))
        .expect_err("a stale epoch is fenced");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
    assert_eq!(ledger.ready_count(), ready_before, "no warm cell consumed");
    assert_eq!(ledger.workcells().len(), cells_before, "no cell minted");
}

// A claim's own epoch never moves the fence: an epoch the registry did not
// issue is refused, and the live runner keeps claiming at its real epoch.
#[test]
fn an_epoch_the_daemon_never_issued_cannot_fence_out_the_live_runner() {
    let (fleet, epoch) = fleet();
    let mut ledger = WorkcellManager::with_warm_pool(1);

    let fenced = fleet
        .claim_workcell(&mut ledger, claim_request("agent-anvil-12", u64::MAX))
        .expect_err("an inflated epoch is fenced");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
    assert_eq!(ledger.ready_count(), 1, "the refusal consumed nothing");

    for agent in ["agent-anvil-13", "agent-anvil-14"] {
        fleet
            .claim_workcell(&mut ledger, claim_request(agent, epoch))
            .expect("the issued epoch still claims after an inflated one");
    }
}

// Re-registering issues a higher epoch, so the previous lifetime is fenced and
// only the new one claims.
#[test]
fn re_registration_fences_the_previous_runner_lifetime() {
    let (mut fleet, old) = fleet();
    let new = fleet.register(daemon(), 1);
    assert!(new > old, "the registry issues a strictly higher epoch");
    let mut ledger = WorkcellManager::with_warm_pool(1);

    let fenced = fleet
        .claim_workcell(&mut ledger, claim_request("agent-anvil-22", old))
        .expect_err("the previous lifetime is fenced");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
    fleet
        .claim_workcell(&mut ledger, claim_request("agent-anvil-23", new))
        .expect("the new lifetime claims");
}

// A drained or reaped runner leaves the claimable set, so the fence entry it
// held is pruned and its claims are refused at the epoch it last held.
#[test]
fn drained_and_reaped_runners_are_pruned_from_the_fence() {
    let (mut fleet, epoch) = fleet();
    let mut ledger = WorkcellManager::with_warm_pool(1);
    fleet
        .claim_workcell(&mut ledger, claim_request("agent-anvil-24", epoch))
        .expect("the active runner claims");

    assert!(fleet.drain(RUNNER));
    assert!(fleet.claimable_runner_epochs().is_empty());
    let fenced = fleet
        .claim_workcell(&mut ledger, claim_request("agent-anvil-25", epoch))
        .expect_err("a draining runner takes no new cell");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");

    let (mut fleet, epoch) = self::fleet();
    let reaped = fleet.reap(1_000);
    assert_eq!(reaped.len(), 1, "the silent runner is reaped");
    let fenced = fleet
        .claim_workcell(&mut ledger, claim_request("agent-anvil-26", epoch))
        .expect_err("a reaped runner is fenced");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
}

fn hold_request(agent_id: &str, runner_epoch: u64) -> HoldFailedTreeRequest {
    HoldFailedTreeRequest {
        claim: claim_request(agent_id, runner_epoch),
        ci_run_id: format!("ci-{agent_id}"),
        failed_run_id: format!("run-{agent_id}"),
        failed_receipt_id: format!("receipt-{agent_id}"),
        failure_log_digest: "sha256:0badc0de".into(),
    }
}

/// Freeze the failed CI run a repair cell produced, presenting the cell's own
/// per-cell token as every per-cell operation must.
fn freeze_repair_cell(
    ledger: &WorkcellManager,
    workcell_id: &str,
    cell_token: u64,
) -> jeryu_runnerd::FrozenCiSnapshot {
    ledger
        .freeze_failed_ci_run(
            workcell_id,
            cell_token,
            FreezeFailedCiRunRequest {
                ci_run_id: format!("ci-{workcell_id}"),
                failed_run_id: format!("run-{workcell_id}"),
                failed_receipt_id: format!("receipt-{workcell_id}"),
                failure_log_digest: "sha256:0badc0de".into(),
                snapshot_age_ms: 0,
            },
        )
        .expect("freeze the repair cell's failed run")
}

// Draining stops every fresh cell: a draining runner's claim and failed-tree
// hold are both fenced before a ready cell is consumed or a cell minted. The
// one thing it may still do is repair from a snapshot of in-flight work it
// froze while active.
#[test]
fn a_draining_runner_repairs_existing_in_flight_work_but_holds_and_claims_nothing() {
    let (mut fleet, epoch) = fleet();
    let mut ledger = WorkcellManager::with_warm_pool(1);
    let held = fleet
        .hold_failed_tree(&mut ledger, hold_request("agent-anvil-30", epoch))
        .expect("the active runner holds its failed tree");
    let snapshot = held.frozen_snapshot.expect("held tree is frozen");

    assert!(fleet.drain(RUNNER));
    let admitted = fleet.admitted_runner_epochs();
    assert_eq!(admitted[RUNNER].epoch, epoch);
    assert_eq!(admitted[RUNNER].admission, RunnerAdmission::Draining);
    assert!(fleet.claimable_runner_epochs().is_empty());

    let ready_before = ledger.ready_count();
    assert_eq!(ready_before, 1, "the warm pool has a ready cell to lose");
    let cells_before = ledger.workcells().len();
    let fenced = fleet
        .hold_failed_tree(&mut ledger, hold_request("agent-anvil-31", epoch))
        .expect_err("a draining runner holds no new failed tree");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
    assert!(
        fenced.message().contains("draining"),
        "{}",
        fenced.message()
    );
    assert_eq!(ledger.ready_count(), ready_before, "no warm cell consumed");
    assert_eq!(ledger.workcells().len(), cells_before, "no cell minted");

    let fenced = fleet
        .claim_workcell(&mut ledger, claim_request("agent-anvil-32", epoch))
        .expect_err("a draining runner takes no fresh cell");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
    assert_eq!(ledger.ready_count(), ready_before, "no warm cell consumed");
    assert_eq!(ledger.workcells().len(), cells_before, "no cell minted");

    let repair = fleet
        .repair_workcell(&mut ledger, &snapshot, rebased())
        .expect("a draining runner repairs its existing in-flight snapshot");
    assert_eq!(repair.state, WorkcellState::Held);
    assert_eq!(repair.admitted_runner_epoch, epoch);

    let mut stale = snapshot.clone();
    stale.admitted_runner_epoch = epoch - 1;
    let fenced = fleet
        .repair_workcell(&mut ledger, &stale, rebased())
        .expect_err("draining admits only the runner's current epoch");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
}

// A reaped runner is dead: it neither holds a failed tree nor repairs a
// snapshot frozen before it died, and no cell is minted for it.
#[test]
fn a_dead_runner_can_neither_hold_nor_repair() {
    let (mut fleet, epoch) = fleet();
    let mut ledger = WorkcellManager::with_warm_pool(1);
    let held = fleet
        .hold_failed_tree(&mut ledger, hold_request("agent-anvil-33", epoch))
        .expect("the live runner holds a failed tree");
    let snapshot = held.frozen_snapshot.expect("held tree is frozen");

    assert_eq!(fleet.reap(1_000).len(), 1, "the silent runner is reaped");
    assert!(fleet.admitted_runner_epochs().is_empty());
    let cells_before = ledger.workcells().len();

    let fenced = fleet
        .hold_failed_tree(&mut ledger, hold_request("agent-anvil-34", epoch))
        .expect_err("a dead runner holds nothing");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
    let fenced = fleet
        .repair_workcell(&mut ledger, &snapshot, rebased())
        .expect_err("a dead runner repairs nothing");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
    assert_eq!(ledger.workcells().len(), cells_before, "no cell minted");
}

// Each repair cell bumps its own per-cell token, but the chain stays fenced on
// the runner's real epoch: hold -> repair -> CI fails -> freeze -> repair
// succeeds, and the second-generation snapshot is still refused once the
// runner re-registers.
#[test]
fn a_snapshot_frozen_from_a_repair_cell_can_be_repaired_again() {
    let (mut fleet, epoch) = fleet();
    let mut ledger = WorkcellManager::with_warm_pool(1);
    let held = fleet
        .hold_failed_tree(&mut ledger, hold_request("agent-anvil-35", epoch))
        .expect("hold the failed tree");
    let first = fleet
        .repair_workcell(
            &mut ledger,
            held.frozen_snapshot.as_ref().expect("frozen"),
            rebased(),
        )
        .expect("first-generation repair");
    assert_eq!(first.runner_epoch, epoch + 1, "per-cell token bumped");
    assert_eq!(first.admitted_runner_epoch, epoch, "lifetime unchanged");

    ledger
        .begin_live_repair(&first.workcell_id, first.runner_epoch)
        .expect("repair starts on the cell's own token");
    let second_snapshot = freeze_repair_cell(&ledger, &first.workcell_id, first.runner_epoch);
    assert_eq!(second_snapshot.runner_epoch, epoch + 1);
    assert_eq!(second_snapshot.admitted_runner_epoch, epoch);

    let second = fleet
        .repair_workcell(&mut ledger, &second_snapshot, rebased())
        .expect("second-generation repair at the runner's real epoch");
    assert_eq!(second.state, WorkcellState::Held);
    assert_eq!(second.runner_epoch, epoch + 2);
    assert_eq!(second.admitted_runner_epoch, epoch);

    fleet.register(daemon(), 1);
    let cells_before = ledger.workcells().len();
    let fenced = fleet
        .repair_workcell(&mut ledger, &second_snapshot, rebased())
        .expect_err("a re-registered runner's old chain is fenced");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
    assert_eq!(
        ledger.workcells().len(),
        cells_before,
        "no repair cell minted"
    );
}

/// Hold a failed tree and repair from its snapshot, both through the fleet.
fn hold_and_repair(
    fleet: &RunnerFleet,
    ledger: &mut WorkcellManager,
    runner_epoch: u64,
) -> jeryu_runnerd::FrozenCiSnapshot {
    let held = fleet
        .hold_failed_tree(
            ledger,
            HoldFailedTreeRequest {
                claim: claim_request("agent-anvil-15", runner_epoch),
                ci_run_id: "ci-anvil-15".into(),
                failed_run_id: "run-anvil-15".into(),
                failed_receipt_id: "receipt-anvil-15".into(),
                failure_log_digest: "sha256:0badc0de".into(),
            },
        )
        .expect("hold the failed tree");
    let snapshot = held.frozen_snapshot.expect("held tree is frozen");
    let repair = fleet
        .repair_workcell(ledger, &snapshot, rebased())
        .expect("repair from the frozen snapshot");
    assert_eq!(repair.state, WorkcellState::Held);
    assert_eq!(
        repair.runner_epoch,
        runner_epoch + 1,
        "the repair cell carries its own bumped fencing token"
    );
    snapshot
}

fn rebased() -> StartupSync {
    StartupSync::Rebased {
        main_ref: "origin/main".into(),
        base_sha: "cc33dd44".into(),
        head_sha: "ee55ff66".into(),
    }
}

// Repair mints its cell at snapshot epoch + 1 as a per-cell token. That bump
// must not become the runner's claim epoch, or the live runner would be
// fenced out of every later claim at its real epoch.
#[test]
fn repair_from_snapshot_does_not_fence_the_live_runner_out_of_claims() {
    let (fleet, epoch) = fleet();
    let mut ledger = WorkcellManager::with_warm_pool(1);
    hold_and_repair(&fleet, &mut ledger, epoch);

    let next = fleet
        .claim_workcell(&mut ledger, claim_request("agent-anvil-16", epoch))
        .expect("the live runner still claims at its real epoch after a repair");
    assert_eq!(next.state, WorkcellState::Claimed);
    let fenced = fleet
        .claim_workcell(&mut ledger, claim_request("agent-anvil-19", epoch + 1))
        .expect_err("the repair's bumped token is not a runner epoch");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
}

// Repair is fenced on the runner lifetime that froze the snapshot: a snapshot
// replayed after the runner re-registered mints no repair cell.
#[test]
fn a_snapshot_kept_past_its_runner_lifetime_cannot_be_repaired() {
    let (mut fleet, epoch) = fleet();
    let mut ledger = WorkcellManager::with_warm_pool(1);
    let snapshot = hold_and_repair(&fleet, &mut ledger, epoch);

    fleet.register(daemon(), 1);
    let cells_before = ledger.workcells().len();
    let fenced = fleet
        .repair_workcell(&mut ledger, &snapshot, rebased())
        .expect_err("a snapshot from a fenced lifetime is refused");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
    assert_eq!(
        ledger.workcells().len(),
        cells_before,
        "no repair cell minted"
    );
}

// Eight agents race for one warm cell behind the daemon's ledger lock:
// exactly one wins and the other seven are denied, with the winner's agent id
// on the lease.
#[test]
fn concurrent_claims_of_one_cell_leave_exactly_one_winner() {
    let manager = Arc::new(Mutex::new(ledger_at(3)));
    let workcell_id = manager.lock().expect("ledger lock").warm_one();

    let racers = 8;
    let barrier = Arc::new(Barrier::new(racers));
    let handles: Vec<_> = (0..racers)
        .map(|index| {
            let manager = Arc::clone(&manager);
            let barrier = Arc::clone(&barrier);
            let workcell_id = workcell_id.clone();
            thread::spawn(move || {
                let request = claim_request(&format!("agent-anvil-race-{index}"), 3);
                barrier.wait();
                let outcome = manager
                    .lock()
                    .expect("ledger lock")
                    .claim_ready(&workcell_id, request);
                outcome
                    .map(|lease| lease.agent_id)
                    .map_err(|err| err.reason)
            })
        })
        .collect();

    let results: Vec<_> = handles
        .into_iter()
        .map(|handle| handle.join().expect("racer finished"))
        .collect();

    let winners: Vec<&String> = results.iter().filter_map(|r| r.as_ref().ok()).collect();
    assert_eq!(winners.len(), 1, "exactly one claim wins: {results:?}");
    for reason in results.iter().filter_map(|r| r.as_ref().err()) {
        assert_eq!(*reason, "workcell_claim_denied");
    }

    let manager = manager.lock().expect("ledger lock");
    let lease = manager.workcell(&workcell_id).expect("lease stays live");
    assert_eq!(lease.state, WorkcellState::Claimed);
    assert_eq!(&lease.agent_id, winners[0], "the winner owns the lease");
    assert_eq!(
        manager.ready_count(),
        0,
        "the cell left the ready queue exactly once"
    );
}
