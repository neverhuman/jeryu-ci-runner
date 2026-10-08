//! A work cell is claimable only from Ready: these drive the real scheduler
//! claim path and assert every refusal, including a concurrent double claim.

use std::sync::{Arc, Barrier, Mutex};
use std::thread;

use jeryu_runnerd::{
    HoldFailedTreeRequest, StartupSync, WorkcellClaimRequest, WorkcellManager, WorkcellState,
};
use std::path::PathBuf;

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
    let mut manager = WorkcellManager::new();
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
    let mut manager = WorkcellManager::new();
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
    let mut manager = WorkcellManager::new();
    let denied = manager
        .claim_ready("wc-not-minted", claim_request("agent-anvil-6", 1))
        .expect_err("an unknown id is not claimable");
    assert_eq!(denied.reason, "workcell_claim_denied");
    assert!(denied.message().contains("unknown warm cell"));
}

// The runner epoch is the fencing token: once the daemon admits epoch 9, a
// claim carrying epoch 8 belongs to a runner lifetime already moved past.
#[test]
fn a_claim_carrying_a_stale_runner_epoch_is_fenced() {
    let mut manager = WorkcellManager::new();
    manager.admit_runner_epoch("runner-anvil-3", 9);
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

// The auto-assigning claim path is fenced on the same token, and refuses
// before it consumes a warm cell or mints a new one.
#[test]
fn the_auto_claim_path_is_fenced_on_a_stale_epoch() {
    let mut manager = WorkcellManager::with_warm_pool(1);
    manager.admit_runner_epoch("runner-anvil-3", 12);
    manager
        .claim(claim_request("agent-anvil-10", 12))
        .expect("the current epoch claims");
    let ready_before = manager.ready_count();
    let cells_before = manager.workcells().len();

    let fenced = manager
        .claim(claim_request("agent-anvil-11", 11))
        .expect_err("a stale epoch is fenced");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
    assert_eq!(manager.ready_count(), ready_before, "no warm cell consumed");
    assert_eq!(manager.workcells().len(), cells_before, "no cell minted");
}

// A claim's own epoch never moves the fence: an epoch the daemon did not
// issue is refused, and the live runner keeps claiming at its real epoch.
#[test]
fn an_epoch_the_daemon_never_issued_cannot_fence_out_the_live_runner() {
    let mut manager = WorkcellManager::new();
    manager.admit_runner_epoch("runner-anvil-3", 5);
    let workcell_id = manager.warm_one();

    let fenced = manager
        .claim_ready(&workcell_id, claim_request("agent-anvil-12", u64::MAX))
        .expect_err("an inflated epoch is fenced");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
    assert_eq!(manager.ready_count(), 1, "the refusal consumed nothing");

    manager
        .claim_ready(&workcell_id, claim_request("agent-anvil-13", 5))
        .expect("the admitted epoch still claims after an inflated one");
    manager
        .claim(claim_request("agent-anvil-14", 5))
        .expect("and keeps claiming on the auto path");
}

fn hold_and_repair(manager: &mut WorkcellManager, runner_epoch: u64) {
    let held = manager
        .hold_failed_tree(HoldFailedTreeRequest {
            claim: claim_request("agent-anvil-15", runner_epoch),
            ci_run_id: "ci-anvil-15".into(),
            failed_run_id: "run-anvil-15".into(),
            failed_receipt_id: "receipt-anvil-15".into(),
            failure_log_digest: "sha256:0badc0de".into(),
        })
        .expect("hold the failed tree");
    let snapshot = held.frozen_snapshot.expect("held tree is frozen");
    let repair = manager
        .repair_from_snapshot(
            &snapshot,
            StartupSync::Rebased {
                main_ref: "origin/main".into(),
                base_sha: "cc33dd44".into(),
                head_sha: "ee55ff66".into(),
            },
        )
        .expect("repair from the frozen snapshot");
    assert_eq!(repair.state, WorkcellState::Held);
    assert_eq!(
        repair.runner_epoch,
        runner_epoch + 1,
        "the repair cell carries its own bumped fencing token"
    );
}

// Repair mints its cell at snapshot epoch + 1 as a per-cell token. That bump
// must not become the runner's claim epoch, or the live runner would be
// fenced out of every later claim at its real epoch.
#[test]
fn repair_from_snapshot_does_not_fence_the_live_runner_out_of_claims() {
    let mut manager = WorkcellManager::with_warm_pool(1);
    hold_and_repair(&mut manager, 4);

    let next = manager
        .claim(claim_request("agent-anvil-16", 4))
        .expect("the live runner still claims at its real epoch after a repair");
    assert_eq!(next.state, WorkcellState::Claimed);
    let warm = manager.warm_one();
    manager
        .claim_ready(&warm, claim_request("agent-anvil-17", 4))
        .expect("and on the warm-pool path");
}

// The same holds when the daemon has admitted the runner's epoch: repair
// neither trips the fence nor moves it.
#[test]
fn repair_under_an_admitted_epoch_leaves_the_fence_where_the_daemon_set_it() {
    let mut manager = WorkcellManager::with_warm_pool(1);
    manager.admit_runner_epoch("runner-anvil-3", 4);
    hold_and_repair(&mut manager, 4);

    manager
        .claim(claim_request("agent-anvil-18", 4))
        .expect("the admitted epoch still claims after a repair");
    let fenced = manager
        .claim(claim_request("agent-anvil-19", 5))
        .expect_err("the repair's bumped token is not a runner epoch");
    assert_eq!(fenced.reason, "workcell_epoch_fenced");
}

// Eight agents race for one warm cell behind the daemon's ledger lock:
// exactly one wins and the other seven are denied, with the winner's agent id
// on the lease.
#[test]
fn concurrent_claims_of_one_cell_leave_exactly_one_winner() {
    let manager = Arc::new(Mutex::new(WorkcellManager::new()));
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
