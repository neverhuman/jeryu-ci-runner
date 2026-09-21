//! Retry budget: `fail()` hands a job to another slot until `max_attempts`.

use super::tests::lease_book;
use super::{JobLeaseState, LeaseError, LeaseEventKind};

#[test]
fn fail_hands_job_to_another_slot_until_max_attempts() {
    let mut leases = lease_book(4);
    let mut previous_ids = Vec::new();
    for attempt in 1..=4u32 {
        let now = 100 + u64::from(attempt) * 100;
        let worker = format!("worker-{attempt}");
        let lease = leases.acquire("test", worker.as_str(), now, 30).unwrap();
        assert_eq!(lease.attempt, attempt);
        assert_eq!(lease.worker_id, worker);
        assert!(!previous_ids.contains(&lease.id));
        previous_ids.push(lease.id.clone());

        leases
            .fail(&lease, format!("flake {attempt}"), now + 10)
            .unwrap();
        if attempt < 4 {
            assert_eq!(leases.state("test"), Some(&JobLeaseState::Pending));
            assert_eq!(leases.attempt("test"), Some(attempt + 1));
        }
    }
    assert_eq!(
        leases.state("test"),
        Some(&JobLeaseState::Failed {
            attempts: 4,
            reason: "flake 4".to_string(),
        })
    );
    assert_eq!(leases.attempt("test"), Some(4));
    assert!(matches!(
        leases.acquire("test", "worker-5", 1_000, 30),
        Err(LeaseError::PermanentlyFailed(job)) if job == "test"
    ));
}

#[test]
fn zero_max_attempts_is_treated_as_a_single_attempt() {
    let mut leases = lease_book(0);
    let lease = leases.acquire("test", "worker-a", 100, 30).unwrap();
    leases.fail(&lease, "boom", 110).unwrap();
    assert!(matches!(
        leases.state("test"),
        Some(JobLeaseState::Failed { attempts: 1, .. })
    ));
}

#[test]
fn rejected_fail_does_not_consume_an_attempt() {
    let mut leases = lease_book(2);
    let first = leases.acquire("test", "worker-a", 100, 30).unwrap();

    // A fail at or after expiry is rejected; the lease stays active.
    assert!(matches!(
        leases.fail(&first, "late", 130),
        Err(LeaseError::LeaseExpired(_))
    ));
    // A fail stamped before acquisition is rejected.
    assert!(matches!(
        leases.fail(&first, "early", 99),
        Err(LeaseError::InvalidLeaseTime(_))
    ));
    assert_eq!(
        leases.state("test"),
        Some(&JobLeaseState::Leased(first.clone()))
    );
    assert_eq!(leases.attempt("test"), Some(1));

    leases.fail(&first, "flake", 110).unwrap();
    // Replaying the same fail against the requeued job must not burn the budget.
    assert!(matches!(
        leases.fail(&first, "flake", 111),
        Err(LeaseError::LeaseMismatch(_))
    ));
    assert_eq!(leases.state("test"), Some(&JobLeaseState::Pending));
    assert_eq!(leases.attempt("test"), Some(2));

    let second = leases.acquire("test", "worker-b", 120, 30).unwrap();
    assert_eq!(second.attempt, 2);
}

#[test]
fn stale_attempt_cannot_fail_the_retry_lease() {
    let mut leases = lease_book(3);
    let first = leases.acquire("test", "worker-a", 100, 30).unwrap();
    leases.fail(&first, "flake", 110).unwrap();
    let second = leases.acquire("test", "worker-b", 120, 30).unwrap();

    assert!(matches!(
        leases.fail(&first, "stale", 125),
        Err(LeaseError::LeaseMismatch(_))
    ));
    assert_eq!(leases.state("test"), Some(&JobLeaseState::Leased(second)));
    assert_eq!(leases.attempt("test"), Some(2));
}

#[test]
fn expiry_and_fail_share_one_retry_budget() {
    let mut leases = lease_book(3);
    let first = leases.acquire("test", "worker-a", 100, 30).unwrap();
    leases.fail(&first, "flake", 110).unwrap();

    leases.acquire("test", "worker-b", 120, 30).unwrap();
    let receipts = leases.expire(150);
    assert_eq!(receipts.len(), 1);
    assert_eq!(receipts[0].kind, LeaseEventKind::Requeued);
    assert_eq!(receipts[0].attempt, 2);

    let third = leases.acquire("test", "worker-c", 160, 30).unwrap();
    assert_eq!(third.attempt, 3);
    let receipts = leases.expire(190);
    assert_eq!(receipts.len(), 1);
    assert_eq!(receipts[0].kind, LeaseEventKind::Failed);
    assert_eq!(receipts[0].attempt, 3);
    assert!(matches!(
        leases.state("test"),
        Some(JobLeaseState::Failed { attempts: 3, reason }) if reason == "lease expired"
    ));
    assert!(leases.expire(1_000).is_empty());
}

#[test]
fn completed_or_cancelled_lease_cannot_be_failed() {
    let mut leases = lease_book(3);
    let lease = leases.acquire("test", "worker-a", 100, 30).unwrap();
    leases.complete(&lease, 110).unwrap();
    assert!(matches!(
        leases.fail(&lease, "late", 115),
        Err(LeaseError::LeaseMismatch(_))
    ));
    assert_eq!(leases.state("test"), Some(&JobLeaseState::Succeeded));

    let mut leases = lease_book(3);
    let lease = leases.acquire("test", "worker-a", 100, 30).unwrap();
    leases.cancel(&lease, "stop", 110).unwrap();
    assert!(matches!(
        leases.fail(&lease, "late", 115),
        Err(LeaseError::LeaseMismatch(_))
    ));
    assert!(matches!(
        leases.state("test"),
        Some(JobLeaseState::Cancelled { attempts: 1, .. })
    ));
}
