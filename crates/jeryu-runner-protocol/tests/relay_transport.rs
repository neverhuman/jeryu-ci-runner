use jeryu_runner_protocol::relay::*;
use std::io::Cursor;

#[test]
fn frames_survive_bytewise_reads_and_preserve_concrete_direction() {
    struct Fragmented(Cursor<Vec<u8>>);
    impl std::io::Read for Fragmented {
        fn read(&mut self, into: &mut [u8]) -> std::io::Result<usize> {
            let length = into.len().min(1);
            std::io::Read::read(&mut self.0, &mut into[..length])
        }
    }
    let frame = GuestRelayFrame::RequestBody {
        request_id: "request-1".into(),
        seq: 1,
        bytes_b64: "AP8b".into(),
    };
    let mut encoded = vec![];
    write_frame(&mut encoded, &frame).unwrap();
    let decoded: GuestRelayFrame =
        read_frame(&mut Fragmented(Cursor::new(encoded.clone()))).unwrap();
    let GuestRelayFrame::RequestBody { bytes_b64, .. } = decoded else {
        panic!("wrong direction")
    };
    assert_eq!(body_bytes(&bytes_b64).unwrap(), vec![0, 255, 27]);
    let error = read_frame::<NodeRelayFrame>(&mut Cursor::new(encoded)).unwrap_err();
    assert_eq!(error.to_string(), "relay_stream_invalid");
}

#[test]
fn oversize_prefix_unknown_fields_and_rejected_credentials_fail_without_echo() {
    for length in [0, MAX_FRAME_BYTES as u32 + 1, u32::MAX] {
        let mut input = Cursor::new(length.to_be_bytes());
        assert!(read_frame::<GuestRelayFrame>(&mut input).is_err());
        assert_eq!(input.position(), 4);
    }
    let rejected = br#"{"type":"cancel","request_id":"request-1","secret":"SHOULD_NEVER_ECHO"}"#;
    let mut input = Cursor::new([&(rejected.len() as u32).to_be_bytes()[..], rejected].concat());
    assert_eq!(
        read_frame::<GuestRelayFrame>(&mut input)
            .unwrap_err()
            .to_string(),
        "relay_stream_invalid"
    );
    let mut sink = vec![];
    let rejected = serde_json::from_str::<GuestRelayFrame>(r#"{"type":"open","request_id":"request-1","provider":"claude","method":"POST","path":"/v1/messages","headers":[],"authorization":"SHOULD_NEVER_ECHO"}"#).unwrap();
    assert_eq!(
        write_frame(&mut sink, &rejected).unwrap_err().to_string(),
        "guest_authorization_rejected"
    );
    assert!(sink.is_empty());
    assert!(read_frame::<GuestRelayFrame>(&mut Cursor::new([0, 0, 0, 5, b'{'])).is_err());
}

#[test]
fn a_full_window_keeps_the_unsent_sequence_retryable_and_rejects_fake_acks() {
    let mut window = SendWindow::default();
    for seq in 1..=32 {
        assert!(window.reserve(seq, MAX_BODY_BYTES).unwrap());
    }
    assert_eq!(window.pending_bytes(), WINDOW_BYTES);
    assert!(!window.reserve(33, MAX_BODY_BYTES).unwrap());
    assert_eq!(window.pending_bytes(), WINDOW_BYTES);
    for ack in [0, 33, u64::MAX] {
        assert!(window.acknowledge(ack).is_err());
    }
    assert_eq!(window.pending_bytes(), WINDOW_BYTES);
    window.acknowledge(1).unwrap();
    assert!(window.reserve(33, MAX_BODY_BYTES).unwrap());
    window.acknowledge(1).unwrap(); // Cumulative duplicate has no extra credit.
    assert_eq!(window.pending_bytes(), WINDOW_BYTES);
    window.acknowledge(2).unwrap();
    assert!(window.acknowledge(1).is_err());
    window.acknowledge(33).unwrap();
    assert_eq!(window.pending_bytes(), 0);
    for bytes in [0, MAX_BODY_BYTES + 1, usize::MAX] {
        assert!(window.reserve(34, bytes).is_err());
    }
    assert!(window.reserve(34, 1).unwrap());
}

#[test]
fn gaps_duplicates_wrong_end_and_frames_after_end_do_not_advance_state() {
    let mut sequence = BodySequence::default();
    assert!(sequence.body(2).is_err());
    assert!(sequence.body(u64::MAX).is_err());
    sequence.body(1).unwrap();
    assert!(sequence.body(1).is_err());
    assert!(sequence.end(0).is_err());
    sequence.body(2).unwrap();
    sequence.end(2).unwrap();
    assert!(sequence.body(3).is_err());
    assert!(sequence.end(2).is_err());
    let mut empty = BodySequence::default();
    empty.end(0).unwrap();
    assert!(empty.body(1).is_err());
}

#[test]
fn tiny_chunks_cannot_grow_the_credit_ledger_past_the_body_window() {
    let mut window = SendWindow::default();
    for seq in 1..=WINDOW_BYTES as u64 {
        assert!(window.reserve(seq, 1).unwrap());
    }
    assert_eq!(window.pending_bytes(), WINDOW_BYTES);
    assert!(!window.reserve(WINDOW_BYTES as u64 + 1, 1).unwrap());
    window.acknowledge(WINDOW_BYTES as u64).unwrap();
    assert_eq!(window.pending_bytes(), 0);
    assert!(window.reserve(WINDOW_BYTES as u64 + 1, 1).unwrap());
}
