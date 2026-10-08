use jeryu_runner_protocol::wire::v2::*;
use serde_json::json;

#[test]
fn responses_are_closed_and_cannot_claim_both_success_and_error() {
    let response = SessionRpcResponse {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-rpc-response".into(),
        request_id: Some("request".into()),
        ok: true,
        result: Some(SessionRpcResult::Grant(GrantApplied { applied: true })),
        error: None,
    };
    SessionRpcResponse::from_json(&response.to_json().unwrap()).unwrap();
    let mut changed = response.clone();
    changed.error = Some(SessionRpcError {
        code: "session_failed".into(),
    });
    assert!(changed.validate().is_err());
    changed.error = None;
    changed.request_id = None;
    assert!(changed.validate().is_err());
    changed.result = None;
    changed.error = Some(SessionRpcError {
        code: "session_rpc_invalid".into(),
    });
    changed.ok = false;
    changed.validate().unwrap();
    let mut value = serde_json::to_value(&response).unwrap();
    value["command"] = json!("/bin/bash");
    assert!(SessionRpcResponse::from_json(&serde_json::to_vec(&value).unwrap()).is_err());
    let mut value = serde_json::to_value(&response).unwrap();
    value["result"]["secret"] = json!("must reject");
    assert!(SessionRpcResponse::from_json(&serde_json::to_vec(&value).unwrap()).is_err());
}
#[test]
fn stream_frames_preserve_binary_and_reject_cross_channel_or_generation_payloads() {
    let frame = TerminalFrame {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-terminal".into(),
        session_id: "session".into(),
        generation: 1,
        run_id: "run".into(),
        channel_id: "shell".into(),
        sequence: 1,
        gap: false,
        bytes: vec![0, 255, 0xe2, 0x82],
    };
    let mut stream = SessionStreamFrame {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-stream".into(),
        request_id: "subscribe".into(),
        session_id: "session".into(),
        generation: 1,
        channel_id: "shell".into(),
        payload: SessionStreamEvent::Terminal { frame },
    };
    let decoded = SessionStreamFrame::from_json(&stream.to_json().unwrap()).unwrap();
    match decoded.payload {
        SessionStreamEvent::Terminal { frame } => assert_eq!(frame.bytes, [0, 255, 0xe2, 0x82]),
        _ => panic!("wrong stream payload"),
    }
    stream.generation = 2;
    assert!(stream.validate().is_err());
    stream.generation = 1;
    stream.channel_id = "agent".into();
    assert!(stream.validate().is_err());
}
#[test]
fn registry_lengths_are_bounded_before_alignment_and_legacy_delivery_modes_rejected() {
    let mut upload = BundleUpload {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "bundle-upload".into(),
        request_id: "upload".into(),
        role: BundleRole::SourceBundle,
        digest: format!("sha256:{}", "a".repeat(64)),
        bundle_bytes: 511,
        stored_bytes: 512,
    };
    upload.validate().unwrap();
    upload.bundle_bytes = u64::MAX;
    assert!(upload.validate().is_err());
    for mode in ["subscription", "api_key"] {
        assert!(serde_json::from_value::<ConnectionMode>(json!(mode)).is_err());
    }
    assert_eq!(
        serde_json::to_value(ConnectionMode::GatewayHelper).unwrap(),
        json!("gateway_helper")
    );
}

#[test]
fn replay_rejects_mixed_authority_reordered_bytes_and_extra_frames() {
    let frame = TerminalFrame {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-terminal".into(),
        session_id: "session".into(),
        generation: 1,
        run_id: "run".into(),
        channel_id: "shell".into(),
        sequence: 7,
        gap: false,
        bytes: vec![255],
    };
    let check = |frames: Vec<TerminalFrame>| {
        SessionRpcResponse {
            protocol_version: PROTOCOL_VERSION.into(),
            message_type: "session-rpc-response".into(),
            request_id: Some("replay".into()),
            ok: true,
            result: Some(SessionRpcResult::Replay(frames)),
            error: None,
        }
        .validate()
    };
    let mut next = frame.clone();
    next.sequence += 1;
    check(vec![frame.clone(), next.clone()]).unwrap();
    for field in ["session", "generation", "run", "channel"] {
        let mut mixed = next.clone();
        match field {
            "session" => mixed.session_id = "other".into(),
            "generation" => mixed.generation = 2,
            "run" => mixed.run_id = "other".into(),
            _ => mixed.channel_id = "agent".into(),
        }
        assert!(check(vec![frame.clone(), mixed]).is_err(), "{field}");
    }
    assert!(check(vec![next, frame.clone()]).is_err());
    assert!(check(vec![frame.clone(), frame.clone()]).is_err());
    let mut jumped = frame.clone();
    jumped.sequence += 5;
    assert!(check(vec![frame.clone(), jumped.clone()]).is_err());
    let mut gap = frame.clone();
    gap.gap = true;
    gap.bytes.clear();
    check(vec![gap.clone(), frame.clone()]).unwrap();
    assert!(check(vec![gap.clone(), jumped]).is_err());
    assert!(check(vec![frame.clone(), gap.clone()]).is_err());
    let frames: Vec<_> = (0..5)
        .map(|i| {
            let mut f = frame.clone();
            f.sequence += i;
            f
        })
        .collect();
    assert!(check(frames.clone()).is_err());
    let mut valid = vec![gap];
    valid.extend(frames.into_iter().take(4));
    check(valid).unwrap();
}

#[test]
fn git_limits_are_required_and_reject_unbounded_preparation() {
    let resources = SessionResources::default();
    resources.validate().unwrap();
    let mut value = serde_json::to_value(resources).unwrap();
    value.as_object_mut().unwrap().remove("git_limits");
    assert!(serde_json::from_value::<SessionResources>(value).is_err());
    for limits in [
        GitLimits {
            timeout_seconds: 0,
            ..GitLimits::default()
        },
        GitLimits {
            stdout_bytes: u32::MAX,
            ..GitLimits::default()
        },
        GitLimits {
            stderr_bytes: u32::MAX,
            ..GitLimits::default()
        },
    ] {
        assert!(
            SessionResources {
                git_limits: limits,
                ..resources
            }
            .validate()
            .is_err()
        );
    }
}
