use super::*;
use jeryu_runner_protocol::wire::v2::SessionContext;

fn context(session: &str, owner: &str) -> SessionContext {
    let digest = format!("sha256:{}", "a".repeat(64));
    SessionContext {
        session_id: session.into(),
        generation: 1,
        run_id: "run".into(),
        owner_id: owner.into(),
        repository: "test/repo".into(),
        source_revision: "a".repeat(40),
        runner_id: "node".into(),
        runner_epoch: 1,
        lease_id: "lease".into(),
        lease_epoch: 1,
        job_digest: digest.clone(),
        environment_digest: digest.clone(),
        runtime_digest: digest.clone(),
        policy_revision: digest,
    }
}
#[test]
fn boot_reservation_releases_lock_and_counts_pending_work_without_cross_owner_stalls() {
    let store = Arc::new(Mutex::new(Registry::default()));
    let first = Reservation::acquire(&store, &context("first", "user/alice"), 2).unwrap();
    assert!(store.try_lock().is_ok());
    let second = Reservation::acquire(&store, &context("second", "user/alice"), 2).unwrap();
    assert!(Reservation::acquire(&store, &context("third", "user/alice"), 2).is_err());
    assert!(Reservation::acquire(&store, &context("first", "user/alice"), 3).is_err());
    assert!(Reservation::acquire(&store, &context("other", "user/bob"), 2).is_ok());
    drop(first);
    assert!(Reservation::acquire(&store, &context("third", "user/alice"), 2).is_ok());
    drop(second);
    assert!(store.lock().unwrap().pending.is_empty());
}
#[test]
fn stopping_releases_owner_quota_but_fences_concurrent_writable_generations() {
    let store = Arc::new(Mutex::new(Registry::default()));
    let first_context = context("first", "user/alice");
    let first = Reservation::acquire(&store, &first_context, 1).unwrap();
    let (handle, state, _) = super::super::test_handle(first_context.clone());
    first.complete(Arc::new(handle)).unwrap();
    assert!(Reservation::acquire(&store, &context("second", "user/alice"), 1).is_err());
    state.lock().unwrap().phase = RuntimePhase::Checkpointing;
    assert!(Reservation::acquire(&store, &context("second", "user/alice"), 1).is_err());
    super::super::shutdown::begin_retention(&state);
    assert_eq!(state.lock().unwrap().phase, RuntimePhase::Stopping);
    assert!(Reservation::acquire(&store, &context("second", "user/alice"), 1).is_ok());
    let mut successor = first_context;
    successor.generation = 2;
    assert!(Reservation::acquire(&store, &successor, 1).is_err());
    state.lock().unwrap().phase = RuntimePhase::Stopped;
    assert!(Reservation::acquire(&store, &successor, 1).is_ok());
}
