use super::*;
use crate::sessions::{AccessGrant, stream_test_handle};
use jeryu_runner_protocol::{guest::GuestEvent, wire::v2::SessionContext};

fn context() -> SessionContext {
    let digest = format!("sha256:{}", "a".repeat(64));
    SessionContext {
        session_id: "session".into(),
        generation: 1,
        run_id: "run".into(),
        owner_id: "user/alice".into(),
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
fn request() -> SessionSubscribe {
    SessionSubscribe {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-subscribe".into(),
        request_id: "subscribe".into(),
        actor: "user/alice".into(),
        session_id: "session".into(),
        generation: 1,
        channel_id: "shell".into(),
        after_sequence: 0,
    }
}
#[tokio::test]
async fn replay_boundary_and_live_queue_preserve_bytes_once_and_drain_before_end() {
    let (handle, ingest) = stream_test_handle(context());
    ingest(GuestEvent::Started {
        channel: "shell".into(),
    })
    .unwrap();
    ingest(GuestEvent::Output {
        channel: "shell".into(),
        sequence: 1,
        bytes: vec![0, 255, 0xe2, 0x82],
    })
    .unwrap();
    let (snapshot, subscription) = handle.subscribe_from("user/alice", "shell", 0).unwrap();
    ingest(GuestEvent::Output {
        channel: "shell".into(),
        sequence: 2,
        bytes: vec![0xac, 27, b'[', b'm'],
    })
    .unwrap();
    ingest(GuestEvent::Exited {
        channel: "shell".into(),
        exit_code: Some(0),
    })
    .unwrap();
    let (send, mut receive) = mpsc::channel(2);
    let thread =
        std::thread::spawn(move || produce(&request(), &handle, snapshot, subscription, &send));
    let mut sequences = vec![];
    let mut bytes = vec![];
    let mut ended = false;
    while let Some(frame) = receive.recv().await {
        let frame = SessionStreamFrame::from_json(&frame).unwrap();
        match frame.payload {
            SessionStreamEvent::Terminal { frame } => {
                sequences.push(frame.sequence);
                bytes.extend(frame.bytes);
            }
            SessionStreamEvent::End { .. } => ended = true,
            _ => assert!(!ended),
        }
    }
    thread.join().unwrap().unwrap();
    assert_eq!(sequences, [1, 2]);
    assert_eq!(bytes, [0, 255, 0xe2, 0x82, 0xac, 27, b'[', b'm']);
    assert!(ended);
}
#[test]
fn future_cursor_rejected_dropped_subscriptions_release_capacity_and_revocation_precedes_replay() {
    let (handle, _ingest) = stream_test_handle(context());
    assert!(handle.subscribe_from("user/alice", "shell", 1).is_err());
    for _ in 0..40 {
        drop(handle.subscribe("user/alice", "shell").unwrap());
    }
    handle
        .grant("user/alice", "user/bob", Some(AccessGrant::Viewer))
        .unwrap();
    let (snapshot, subscription) = handle.subscribe_from("user/bob", "shell", 0).unwrap();
    handle.grant("user/alice", "user/bob", None).unwrap();
    let (send, mut receive) = mpsc::channel(2);
    let mut request = request();
    request.actor = "user/bob".into();
    assert_eq!(
        produce(&request, &handle, snapshot, subscription, &send)
            .unwrap_err()
            .code(),
        "session_access_forbidden"
    );
    assert!(receive.try_recv().is_err());
}
#[test]
fn slow_stream_disconnects_within_a_bound_without_waiting_on_guest_production() {
    let (handle, _ingest) = stream_test_handle(context());
    let (send, _receive) = mpsc::channel(1);
    send.try_send(Bytes::from_static(b"occupied")).unwrap();
    let started = Instant::now();
    let error = emit(&request(), &handle, &send, SessionStreamEvent::Heartbeat).unwrap_err();
    assert_eq!(error.code(), "session_stream_backpressure");
    assert!(started.elapsed() >= Duration::from_secs(2));
    assert!(started.elapsed() < Duration::from_secs(4));
}
