mod fencing;
mod handle;
mod registry;
mod shutdown;
use super::{
    RunnerResult,
    control::ControllerLease,
    failed,
    replay::{Subscription, Viewer},
    state::{AccessGrant, RuntimePhase, SessionSnapshot, State},
};
use jeryu_runner_core::{ExecutionPurpose, RunnerClass, receipt::now_ms};
use jeryu_runner_microvm::{MicroVmSession, artifacts::VerifiedRuntime, supervisor::Node};
use jeryu_runner_protocol::{
    guest::{GuestProfile, GuestRequest},
    wire::v2::{ControlAck, ControlRequest, SessionLease, TerminalFrame, WorkspaceSyncState},
};
use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, SyncSender},
    },
    time::Duration,
};

pub struct SessionService {
    node: Arc<Node>,
    runtime: Arc<VerifiedRuntime>,
    sessions: Arc<Mutex<registry::Registry>>,
    owner_limit: usize,
}
pub struct SessionHandle {
    state: Arc<Mutex<State>>,
    commands: SyncSender<GuestRequest>,
    fences: SyncSender<GuestRequest>,
    handoff: Mutex<()>,
    fence_id: AtomicU64,
    stop: Arc<AtomicBool>,
    expires_at_unix_millis: u64,
}

impl SessionService {
    pub fn new(node: Arc<Node>, runtime: Arc<VerifiedRuntime>) -> Self {
        Self {
            node,
            runtime,
            sessions: Arc::new(Mutex::new(registry::Registry::default())),
            owner_limit: 2,
        }
    }
    /// Trusted service configuration, never a lease/caller override. Canary
    /// qualification can admit three sessions while production defaults to two.
    pub fn with_owner_limit(mut self, owner_limit: usize) -> RunnerResult<Self> {
        if !(1..=64).contains(&owner_limit) {
            return Err(failed("session_owner_limit_invalid"));
        }
        self.owner_limit = owner_limit;
        Ok(self)
    }
    pub fn start(&self, lease: SessionLease) -> RunnerResult<Arc<SessionHandle>> {
        ExecutionPurpose::ManagedAgent.require_runner(RunnerClass::MicroVmRust)?;
        self.validate(&lease)?;
        let reservation =
            registry::Reservation::acquire(&self.sessions, &lease.context, self.owner_limit)?;
        let mut session = MicroVmSession::start(self.node.clone(), &self.runtime, lease.clone())?;
        let mut reader = session.take_reader()?;
        let mut initial_state = State::new(lease.context.clone());
        initial_state.workspace = session.workspace_ready().cloned();
        let rebase_required = initial_state
            .workspace
            .as_ref()
            .is_some_and(|ready| ready.sync_state == WorkspaceSyncState::RebaseRequired);
        if rebase_required {
            initial_state.phase = RuntimePhase::RebaseRequired;
            initial_state.reason = Some("main_sync_conflict".into());
        }
        let state = Arc::new(Mutex::new(initial_state));
        let stop = Arc::new(AtomicBool::new(false));
        let (commands, requests) = mpsc::sync_channel::<GuestRequest>(64);
        let (fences, fence_requests) = mpsc::sync_channel::<GuestRequest>(4);
        let handle = Arc::new(SessionHandle {
            state: state.clone(),
            commands,
            fences,
            handoff: Mutex::new(()),
            fence_id: AtomicU64::new(0),
            stop: stop.clone(),
            expires_at_unix_millis: lease.expires_at_unix_millis,
        });
        session.send(&GuestRequest::Start {
            channel: "shell".into(),
            profile: GuestProfile::Shell,
        })?;
        if !rebase_required {
            session.send(&GuestRequest::Start {
                channel: "agent".into(),
                profile: GuestProfile::registered(&lease.profile_id)
                    .map_err(|_| failed("unknown_agent_profile"))?,
            })?;
        }
        let reading_state = state.clone();
        let reading_stop = stop.clone();
        let reader_done = Arc::new(AtomicBool::new(false));
        let reading_done = reader_done.clone();
        std::thread::spawn(move || {
            while !reading_done.load(Ordering::Acquire) {
                match reader.poll(Duration::from_millis(100)) {
                    Ok(Some(event)) => {
                        let Ok(mut state) = reading_state.lock() else {
                            break;
                        };
                        if state.ingest(event).is_err() {
                            state.finish(RuntimePhase::Failed, Some("guest_session_failed".into()));
                            reading_stop.store(true, Ordering::Release);
                        }
                        if state.phase == RuntimePhase::Stopping {
                            reading_stop.store(true, Ordering::Release);
                        }
                    }
                    Ok(None) => (),
                    Err(error) => {
                        if let Ok(mut state) = reading_state.lock()
                            && matches!(
                                state.phase,
                                RuntimePhase::Running | RuntimePhase::RebaseRequired
                            )
                        {
                            state.finish(RuntimePhase::Failed, Some(error.code().into()));
                        }
                        reading_stop.store(true, Ordering::Release);
                        break;
                    }
                }
            }
        });
        std::thread::spawn(move || {
            while !stop.load(Ordering::Acquire) {
                if now_ms() >= u128::from(lease.expires_at_unix_millis.saturating_sub(3000)) {
                    if let Ok(mut state) = state.lock() {
                        state.reason = Some("runtime_limit".into());
                    }
                    break;
                }
                if let Ok(fence) = fence_requests.try_recv() {
                    if let Err(error) = session.send(&fence) {
                        if let Ok(mut state) = state.lock() {
                            state.finish(RuntimePhase::Failed, Some(error.code().into()));
                        }
                        break;
                    }
                    continue;
                }
                let request = match requests.recv_timeout(Duration::from_millis(10)) {
                    Ok(request) => request,
                    Err(mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(_) => break,
                };
                let id = match &request {
                    GuestRequest::Input { request_id, .. }
                    | GuestRequest::Resize { request_id, .. }
                    | GuestRequest::Interrupt { request_id, .. }
                    | GuestRequest::Stop { request_id } => request_id,
                    _ => break,
                };
                {
                    let Ok(mut state) = state.lock() else {
                        break;
                    };
                    if !state.authorize_pending(id) {
                        let _ = state.acknowledge_guest(id, false, "session_control_revoked", true);
                        continue;
                    }
                }
                if matches!(request, GuestRequest::Stop { .. }) {
                    let flushed = shutdown::freeze(&mut session, &state, id);
                    reader_done.store(true, Ordering::Release);
                    shutdown::begin_retention(&state);
                    let result = session.stop();
                    if let Ok(mut state) = state.lock() {
                        state.checkpoint = session.checkpoint().cloned();
                        let _ = state.acknowledge_guest(
                            id,
                            result.is_ok(),
                            if result.is_ok() {
                                "applied"
                            } else {
                                "cleanup_failed"
                            },
                            true,
                        );
                        shutdown::finish_retention(&mut state, result, flushed);
                    }
                    return;
                }
                if let Err(error) = session.send(&request) {
                    if let Ok(mut state) = state.lock() {
                        let _ = state.acknowledge_guest(id, false, error.code(), true);
                        state.finish(RuntimePhase::Failed, Some(error.code().into()));
                    }
                    break;
                }
            }
            let flushed = shutdown::freeze(&mut session, &state, "service-stop-freeze");
            reader_done.store(true, Ordering::Release);
            shutdown::begin_retention(&state);
            let result = session.stop();
            if let Ok(mut state) = state.lock() {
                state.checkpoint = session.checkpoint().cloned();
                shutdown::finish_retention(&mut state, result, flushed);
            }
        });
        reservation.complete(handle.clone())?;
        Ok(handle)
    }
    pub fn validate(&self, lease: &SessionLease) -> RunnerResult<()> {
        self.node.validate_lease(lease)?;
        if lease.runtime != *self.runtime.manifest() {
            return Err(failed("microvm_runtime_mismatch"));
        }
        GuestProfile::registered(&lease.profile_id).map_err(|_| failed("unknown_agent_profile"))?;
        Ok(())
    }
    pub fn get(
        &self,
        actor: &str,
        session_id: &str,
        generation: u64,
    ) -> RunnerResult<Arc<SessionHandle>> {
        let sessions = self
            .sessions
            .lock()
            .map_err(|_| failed("session_registry_failed"))?;
        let handle = sessions
            .sessions
            .get(&(session_id.into(), generation))
            .ok_or_else(|| failed("session_not_found"))?;
        handle.snapshot(actor)?;
        Ok(handle.clone())
    }
}

#[cfg(test)]
pub(super) fn test_handle(
    context: jeryu_runner_protocol::wire::v2::SessionContext,
) -> (
    SessionHandle,
    Arc<Mutex<State>>,
    mpsc::Receiver<GuestRequest>,
) {
    let state = Arc::new(Mutex::new(State::new(context)));
    let (commands, receive) = mpsc::sync_channel(64);
    let (fences, fence_requests) = mpsc::sync_channel::<GuestRequest>(4);
    let fake_state = state.clone();
    std::thread::spawn(move || {
        while let Ok(GuestRequest::ControlFence {
            request_id, epoch, ..
        }) = fence_requests.recv()
        {
            fake_state
                .lock()
                .unwrap()
                .ingest(jeryu_runner_protocol::guest::GuestEvent::ControlFenced {
                    request_id,
                    epoch,
                })
                .unwrap();
        }
    });
    (
        SessionHandle {
            fences,
            handoff: Mutex::new(()),
            fence_id: AtomicU64::new(0),
            state: state.clone(),
            commands,
            stop: Arc::new(AtomicBool::new(false)),
            expires_at_unix_millis: u64::MAX,
        },
        state,
        receive,
    )
}

#[cfg(test)]
pub(crate) fn stream_test_handle(
    context: jeryu_runner_protocol::wire::v2::SessionContext,
) -> (
    SessionHandle,
    impl Fn(jeryu_runner_protocol::guest::GuestEvent) -> RunnerResult<()> + Send + Sync,
) {
    let (handle, state, _) = test_handle(context);
    (handle, move |event| {
        state
            .lock()
            .map_err(|_| failed("session_state_failed"))?
            .ingest(event)
    })
}
