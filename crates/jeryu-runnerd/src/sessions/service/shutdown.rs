//! A freeze window is inside the execution lease, never an extension of it.
use super::*;
use std::time::Instant;

/// The guest freeze is complete or exhausted. Retention no longer consumes
/// owner execution quota, but node resources and generation fencing stay held.
pub(super) fn begin_retention(state: &Arc<Mutex<State>>) {
    if let Ok(mut state) = state.lock() {
        state.control_ready = false;
        if state.phase != RuntimePhase::Failed {
            state.phase = RuntimePhase::Stopping;
        }
        let snapshot = state.snapshot();
        state.publish(super::super::state::SessionEvent::Snapshot(snapshot));
    }
}
pub(super) fn finish_retention(state: &mut State, result: RunnerResult<()>, flushed: bool) {
    let failed = state.phase == RuntimePhase::Failed || result.is_err();
    let reason = result
        .err()
        .map(|error| error.code().into())
        .or_else(|| state.reason.clone())
        .or_else(|| (!flushed).then(|| "checkpoint_unflushed".into()));
    state.finish(
        if failed {
            RuntimePhase::Failed
        } else {
            RuntimePhase::Stopped
        },
        reason,
    );
}

pub(super) fn freeze(session: &mut MicroVmSession, state: &Arc<Mutex<State>>, id: &str) -> bool {
    let already = {
        let Ok(mut state) = state.lock() else {
            return false;
        };
        if state.automatic_frozen {
            true
        } else {
            if !matches!(
                state.phase,
                RuntimePhase::Running | RuntimePhase::RebaseRequired
            ) {
                return false;
            }
            state.control_ready = false;
            state.phase = RuntimePhase::Checkpointing;
            state.pending_freeze = Some(id.into());
            false
        }
    };
    if !already
        && session
            .send(&GuestRequest::Freeze {
                request_id: id.into(),
            })
            .is_err()
    {
        return false;
    }
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline {
        let Ok(state) = state.lock() else {
            return false;
        };
        if state.automatic_frozen || state.frozen_request.as_deref() == Some(id) {
            return session
                .mark_workspace_flushed(state.workspace.clone())
                .is_ok();
        }
        if state.phase == RuntimePhase::Failed {
            return false;
        }
        drop(state);
        std::thread::sleep(Duration::from_millis(10));
    }
    false
}

#[cfg(test)]
mod tests;
