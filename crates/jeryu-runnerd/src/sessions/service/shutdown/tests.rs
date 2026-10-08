use super::*;
use crate::sessions::tests::context;

#[test]
fn a_contextual_rebase_conflict_does_not_make_a_clean_direct_stop_fail() {
    let state = Arc::new(Mutex::new(State::new(context())));
    {
        let mut state = state.lock().unwrap();
        state.phase = RuntimePhase::Checkpointing;
        state.reason = Some("main_sync_conflict".into());
        state.control_ready = true;
    }
    begin_retention(&state);
    let mut state = state.lock().unwrap();
    assert_eq!(state.phase, RuntimePhase::Stopping);
    assert!(!state.control_ready);
    finish_retention(&mut state, Ok(()), true);
    assert_eq!(state.phase, RuntimePhase::Stopped);
    assert_eq!(state.reason.as_deref(), Some("main_sync_conflict"));
}

#[test]
fn actual_guest_and_cleanup_failures_are_never_hidden_by_successful_retention() {
    let state = Arc::new(Mutex::new(State::new(context())));
    state
        .lock()
        .unwrap()
        .finish(RuntimePhase::Failed, Some("guest_session_failed".into()));
    begin_retention(&state);
    let mut state = state.lock().unwrap();
    assert_eq!(state.phase, RuntimePhase::Failed);
    finish_retention(&mut state, Ok(()), false);
    assert_eq!(state.phase, RuntimePhase::Failed);
    assert_eq!(state.reason.as_deref(), Some("guest_session_failed"));
    finish_retention(&mut state, Err(failed("cleanup_failed")), true);
    assert_eq!(state.phase, RuntimePhase::Failed);
    assert_eq!(state.reason.as_deref(), Some("cleanup_failed"));
}

#[test]
fn missing_freeze_is_explicit_and_does_not_invent_a_flushed_checkpoint() {
    let mut state = State::new(context());
    finish_retention(&mut state, Ok(()), false);
    assert_eq!(state.phase, RuntimePhase::Stopped);
    assert_eq!(state.reason.as_deref(), Some("checkpoint_unflushed"));
    assert!(state.checkpoint.is_none());
}
