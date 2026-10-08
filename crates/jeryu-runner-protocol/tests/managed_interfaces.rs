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
