use super::{service::test_handle, *};
use jeryu_runner_protocol::{
    guest::{GuestEvent, GuestRequest},
    wire::v2::*,
};
use std::time::Duration;

pub(super) fn context() -> SessionContext {
    let digest = format!("sha256:{}", "a".repeat(64));
    SessionContext {
        session_id: "session-1".into(),
        generation: 1,
        run_id: "run-1".into(),
        owner_id: "user/alice".into(),
        repository: "alice/repo".into(),
        source_revision: "a".repeat(40),
        runner_id: "node".into(),
        runner_epoch: 1,
        lease_id: "lease-1".into(),
        lease_epoch: 1,
        job_digest: digest.clone(),
        environment_digest: digest.clone(),
        runtime_digest: digest.clone(),
        policy_revision: digest,
    }
}

#[test]
fn conflict_state_rejects_agent_channel_and_allows_companion_shell() {
    let (handle, state, _) = test_handle(context());
    state.lock().unwrap().phase = RuntimePhase::RebaseRequired;
    assert_eq!(
        state
            .lock()
            .unwrap()
            .ingest(GuestEvent::Started {
                channel: "agent".into()
            })
            .unwrap_err()
            .code(),
        "guest_rebase_required"
    );
    state
        .lock()
        .unwrap()
        .ingest(GuestEvent::Started {
            channel: "shell".into(),
        })
        .unwrap();
    let snapshot = handle.snapshot("user/alice").unwrap();
    assert_eq!(snapshot.phase, RuntimePhase::RebaseRequired);
    assert!(
        snapshot
            .channels
            .iter()
            .any(|c| c.channel_id == "shell" && c.started)
    );
    assert!(
        snapshot
            .channels
            .iter()
            .any(|c| c.channel_id == "agent" && !c.started)
    );
}
fn request(id: &str, sequence: u64, epoch: u64, actor: &str) -> ControlRequest {
    ControlRequest {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-control".into(),
        context: context(),
        request_id: id.into(),
        channel_id: "shell".into(),
        controller_id: format!("{actor}-client"),
        control_lease_epoch: epoch,
        control_sequence: sequence,
        command: ControlCommand::Resize { rows: 24, cols: 80 },
    }
}
fn guest_id(request: GuestRequest) -> String {
    match request {
        GuestRequest::Resize { request_id, .. } | GuestRequest::Stop { request_id } => request_id,
        _ => panic!("wrong request"),
    }
}

#[test]
fn control_requires_owner_grants_current_lease_and_exact_context() {
    let (handle, state, receive) = test_handle(context());
    assert_eq!(
        handle.snapshot("user/bob").unwrap_err().code(),
        "session_access_forbidden"
    );
    handle
        .grant("user/alice", "user/bob", Some(AccessGrant::Viewer))
        .unwrap();
    assert!(handle.snapshot("user/bob").is_ok());
    assert!(
        handle
            .acquire_control("user/bob", "user/bob-client", &[], false)
            .is_err()
    );
    handle
        .grant("user/alice", "user/bob", Some(AccessGrant::Controller))
        .unwrap();
    let bob = handle
        .acquire_control("user/bob", "user/bob-client", &[], false)
        .unwrap();
    assert_eq!(
        handle
            .acquire_control("user/alice", "user/alice-client", &[], false)
            .unwrap_err()
            .code(),
        "session_control_busy"
    );
    let alice = handle
        .acquire_control("user/alice", "user/alice-client", &[], true)
        .unwrap();
    assert!(alice.epoch > bob.epoch);
    assert!(
        handle
            .control("user/bob", request("bob-1", 1, bob.epoch, "user/bob"))
            .is_err()
    );
    let original = request("control-1", 1, alice.epoch, "user/alice");
    let mut different = original.clone();
    different.context.generation += 1;
    assert_eq!(
        handle.control("user/alice", different).unwrap_err().code(),
        "session_control_fenced"
    );
    assert_eq!(
        handle
            .control("user/alice", original.clone())
            .unwrap()
            .state,
        ControlState::Accepted
    );
    let guest_id = guest_id(receive.try_recv().unwrap());
    assert_ne!(guest_id, original.request_id);
    state
        .lock()
        .unwrap()
        .ingest(GuestEvent::Ack {
            request_id: guest_id,
            applied: true,
            reason: "applied".into(),
        })
        .unwrap();
    let ack = handle.acknowledgement("user/alice", "control-1").unwrap();
    ack.validate_for(&original).unwrap();
    assert_eq!(ack.state, ControlState::Applied);
    assert_eq!(
        handle.control("user/alice", original).unwrap().state,
        ControlState::Applied
    );
    assert!(receive.try_recv().is_err());
    assert_eq!(
        handle
            .control(
                "user/alice",
                request("control-2", 1, alice.epoch, "user/alice")
            )
            .unwrap_err()
            .code(),
        "session_control_replay"
    );
    let mut prompt = request("prompt", 2, alice.epoch, "user/alice");
    prompt.command = ControlCommand::Prompt {
        text: "secret prompt".into(),
    };
    assert_eq!(
        handle.control("user/alice", prompt).unwrap_err().code(),
        "session_structured_prompt_unsupported"
    );
}

#[test]
fn bounded_viewer_queues_resync_without_blocking_other_viewers_and_revocation_is_immediate() {
    let (handle, state, _) = test_handle(context());
    state
        .lock()
        .unwrap()
        .ingest(GuestEvent::Started {
            channel: "agent".into(),
        })
        .unwrap();
    handle
        .grant("user/alice", "user/bob", Some(AccessGrant::Viewer))
        .unwrap();
    let slow = handle.subscribe("user/bob", "agent").unwrap();
    let fast = handle.subscribe("user/alice", "agent").unwrap();
    for sequence in 1..=40 {
        state
            .lock()
            .unwrap()
            .ingest(GuestEvent::Output {
                channel: "agent".into(),
                sequence,
                bytes: vec![0, 255, 0xe2, 0x82],
            })
            .unwrap();
        match fast.next(Duration::from_millis(1)).unwrap().unwrap() {
            SessionEvent::Terminal(frame) => {
                assert_eq!(frame.sequence, sequence);
                assert!(!frame.gap);
            }
            _ => panic!("wrong event"),
        }
    }
    match slow.next(Duration::from_millis(1)).unwrap().unwrap() {
        SessionEvent::Terminal(frame) => assert!(frame.gap),
        _ => panic!("gap missing"),
    }
    assert_eq!(
        handle.replay("user/bob", "agent", 0, 128).unwrap().len(),
        40
    );
    handle.grant("user/alice", "user/bob", None).unwrap();
    assert_eq!(
        slow.next(Duration::ZERO).unwrap_err().code(),
        "session_access_revoked"
    );
}

#[test]
fn replay_is_rejected_after_receipt_eviction_and_pending_controls_are_rechecked() {
    let (handle, state, receive) = test_handle(context());
    let lease = handle
        .acquire_control("user/alice", "user/alice-client", &[], false)
        .unwrap();
    for sequence in 1..=1030 {
        handle
            .control(
                "user/alice",
                request(
                    &format!("control-{sequence}"),
                    sequence,
                    lease.epoch,
                    "user/alice",
                ),
            )
            .unwrap();
        let id = guest_id(receive.try_recv().unwrap());
        state
            .lock()
            .unwrap()
            .ingest(GuestEvent::Ack {
                request_id: id,
                applied: true,
                reason: "applied".into(),
            })
            .unwrap();
    }
    assert!(handle.acknowledgement("user/alice", "control-1").is_err());
    assert_eq!(
        handle
            .control(
                "user/alice",
                request("control-1", 1, lease.epoch, "user/alice")
            )
            .unwrap_err()
            .code(),
        "session_control_replay"
    );
    handle
        .grant("user/alice", "user/bob", Some(AccessGrant::Controller))
        .unwrap();
    handle.grant("user/alice", "user/alice", None).unwrap_err();
    let mut state = state.lock().unwrap();
    state.controller.as_mut().unwrap().expires = std::time::Instant::now() - Duration::from_secs(1);
    let bob = state
        .acquire_control("user/bob", "user/bob-client", &[], false)
        .unwrap();
    let (request_id, epoch) = state
        .pending_fence
        .clone()
        .unwrap_or(("unit-fence".into(), bob.epoch));
    state.pending_fence = Some((request_id.clone(), epoch));
    state
        .ingest(GuestEvent::ControlFenced { request_id, epoch })
        .unwrap();
    let (_, command) = state
        .prepare_control("user/bob", &request("pending", 1, bob.epoch, "user/bob"))
        .unwrap();
    let id = guest_id(command.unwrap());
    assert!(state.authorize_pending(&id));
    state.grants.remove("user/bob");
    assert!(!state.authorize_pending(&id));
}

#[test]
fn guest_ack_cannot_claim_vm_cleanup_and_terminal_tail_is_bounded() {
    let (handle, state, receive) = test_handle(context());
    let controller = handle
        .acquire_control("user/alice", "user/alice-client", &[], false)
        .unwrap();
    let mut stop = request("stop", 1, controller.epoch, "user/alice");
    stop.command = ControlCommand::Stop;
    handle.control("user/alice", stop).unwrap();
    let id = guest_id(receive.try_recv().unwrap());
    assert_eq!(
        state
            .lock()
            .unwrap()
            .ingest(GuestEvent::Ack {
                request_id: id,
                applied: true,
                reason: "applied".into()
            })
            .unwrap_err()
            .code(),
        "guest_stop_ack_denied"
    );
    state
        .lock()
        .unwrap()
        .ingest(GuestEvent::Started {
            channel: "agent".into(),
        })
        .unwrap();
    for sequence in 1..=650 {
        state
            .lock()
            .unwrap()
            .ingest(GuestEvent::Output {
                channel: "agent".into(),
                sequence,
                bytes: vec![b'x'; MAX_TERMINAL_BYTES],
            })
            .unwrap();
    }
    let replay = handle.replay("user/alice", "agent", 0, 128).unwrap();
    assert!(replay[0].gap);
    assert!(replay[0].sequence > 1);
    let mut changed = request("changed", 2, controller.epoch, "user/alice");
    changed.command = ControlCommand::Input { bytes: vec![0] };
    changed.request_id = "stop".into();
    assert_eq!(
        handle.control("user/alice", changed).unwrap_err().code(),
        "session_control_replay_conflict"
    );
}

#[test]
fn two_clients_of_one_actor_do_not_share_a_writer_and_screens_are_bound() {
    let (handle, state, _) = test_handle(context());
    let first = handle
        .acquire_control("user/alice", "first-client", &[], false)
        .unwrap();
    assert_eq!(
        handle
            .acquire_control("user/alice", "second-client", &[], false)
            .unwrap_err()
            .code(),
        "session_control_busy"
    );
    let renewed = handle
        .acquire_control("user/alice", "first-client", &["shell".into()], false)
        .unwrap();
    assert_eq!(first.epoch, renewed.epoch);
    let second = handle
        .acquire_control("user/alice", "second-client", &[], true)
        .unwrap();
    assert!(second.epoch > first.epoch);
    let mut previous = request("old-writer", 1, first.epoch, "user/alice");
    previous.controller_id = "first-client".into();
    assert!(handle.control("user/alice", previous).is_err());
    state
        .lock()
        .unwrap()
        .ingest(GuestEvent::Started {
            channel: "shell".into(),
        })
        .unwrap();
    let screen = ScreenSnapshot {
        sequence: 0,
        rows: 24,
        cols: 80,
        cursor_row: 0,
        cursor_col: 0,
        text: "screen".into(),
        truncated: false,
    };
    state
        .lock()
        .unwrap()
        .ingest(GuestEvent::Screen {
            channel: "shell".into(),
            screen: screen.clone(),
        })
        .unwrap();
    assert_eq!(handle.screen("user/alice", "shell").unwrap().screen, screen);
    assert!(handle.screen("user/bob", "shell").is_err());
    let mut future = screen;
    future.sequence = 1;
    assert!(
        state
            .lock()
            .unwrap()
            .ingest(GuestEvent::Screen {
                channel: "shell".into(),
                screen: future
            })
            .is_err()
    );
}

#[test]
fn freeze_acks_need_a_trusted_pending_request_and_lifecycle_stops_are_single_use() {
    let (_, state, _) = test_handle(context());
    let mut state = state.lock().unwrap();
    state.phase = RuntimePhase::Checkpointing;
    assert!(
        state
            .ingest(GuestEvent::Frozen {
                request_id: "unsolicited".into(),
                workspace: None
            })
            .is_err()
    );
    state.pending_freeze = Some("expected".into());
    state
        .ingest(GuestEvent::Frozen {
            request_id: "expected".into(),
            workspace: None,
        })
        .unwrap();
    assert_eq!(state.frozen_request.as_deref(), Some("expected"));
    state.phase = RuntimePhase::Running;
    let event = GuestEvent::LifecycleStopped {
        reason: jeryu_runner_protocol::guest::LifecycleReason::IdleTimeout,
        workspace: None,
    };
    state.ingest(event.clone()).unwrap();
    assert!(state.automatic_frozen);
    assert_eq!(state.phase, RuntimePhase::Stopping);
    assert_eq!(state.reason.as_deref(), Some("idle_timeout"));
    assert!(state.ingest(event).is_err());
}
