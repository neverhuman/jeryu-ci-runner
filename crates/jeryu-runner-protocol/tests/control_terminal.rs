use jeryu_runner_protocol::wire::v2::*;
fn context() -> SessionContext {
    let digest = format!("sha256:{}", "a".repeat(64));
    SessionContext {
        session_id: "session".into(),
        generation: 1,
        run_id: "run".into(),
        owner_id: "user/alice".into(),
        repository: "alice/repo".into(),
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
fn request(operation: SessionRpcOperation) -> SessionRpcRequest {
    SessionRpcRequest {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-rpc".into(),
        request_id: "req".into(),
        operation,
    }
}
fn response(result: SessionRpcResult) -> SessionRpcResponse {
    SessionRpcResponse {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-rpc-response".into(),
        request_id: Some("req".into()),
        ok: true,
        result: Some(result),
        error: None,
    }
}
#[test]
fn named_calls_cannot_complete_from_uncorrelated_error_envelopes() {
    let request = request(SessionRpcOperation::Snapshot {
        actor: "user/alice".into(),
        session_id: "session".into(),
        generation: 1,
    });
    let mut error = SessionRpcResponse {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-rpc-response".into(),
        request_id: None,
        ok: false,
        result: None,
        error: Some(SessionRpcError {
            code: "session_rpc_invalid".into(),
        }),
    };
    error.validate().unwrap();
    assert!(error.validate_for(&request, &context()).is_err());
    error.request_id = Some("different-call".into());
    assert!(error.validate_for(&request, &context()).is_err());
    error.request_id = Some(request.request_id.clone());
    error.validate_for(&request, &context()).unwrap();
}
#[test]
fn writer_replies_bind_the_principal_attachment_channels_and_signed_context() {
    let request = request(SessionRpcOperation::AcquireControl {
        actor: "user/alice".into(),
        controller_id: "attachment".into(),
        terminal_channels: vec!["shell".into()],
        session_id: "session".into(),
        generation: 1,
        takeover: false,
    });
    let lease = ControllerLease {
        context: context(),
        actor: "user/alice".into(),
        controller_id: "attachment".into(),
        terminal_channels: vec!["shell".into()],
        epoch: 1,
        expires_in_seconds: 30,
        next_sequence: 1,
    };
    response(SessionRpcResult::Controller(lease.clone()))
        .validate_for(&request, &context())
        .unwrap();
    for index in 0..4 {
        let mut changed = lease.clone();
        match index {
            0 => changed.actor = "user/bob".into(),
            1 => changed.controller_id = "another-client".into(),
            2 => changed.terminal_channels.clear(),
            _ => changed.context.generation += 1,
        }
        assert!(
            response(SessionRpcResult::Controller(changed))
                .validate_for(&request, &context())
                .is_err()
        );
    }
}
#[test]
fn screens_bind_the_channel_and_context_and_bound_text_dimensions_and_cursor() {
    let request = request(SessionRpcOperation::Screen {
        actor: "user/alice".into(),
        session_id: "session".into(),
        generation: 1,
        channel_id: "shell".into(),
    });
    let screen = TerminalScreen {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "terminal-screen".into(),
        context: context(),
        channel_id: "shell".into(),
        screen: ScreenSnapshot {
            sequence: 0,
            rows: 24,
            cols: 80,
            cursor_row: 0,
            cursor_col: 0,
            text: "€".into(),
            truncated: false,
        },
    };
    response(SessionRpcResult::Screen(screen.clone()))
        .validate_for(&request, &context())
        .unwrap();
    for index in 0..5 {
        let mut changed = screen.clone();
        match index {
            0 => changed.channel_id = "agent".into(),
            1 => changed.context.generation += 1,
            2 => changed.screen.rows = 201,
            3 => changed.screen.cursor_col = 80,
            _ => changed.screen.text = "€".repeat(21846),
        }
        assert!(
            response(SessionRpcResult::Screen(changed))
                .validate_for(&request, &context())
                .is_err()
        );
    }
    assert!(!format!("{screen:?}").contains('€'));
}
