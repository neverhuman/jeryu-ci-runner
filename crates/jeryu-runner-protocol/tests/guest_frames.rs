use jeryu_runner_protocol::guest::*;
use std::io::Cursor;

#[test]
fn guest_frames_preserve_raw_bytes_and_reject_oversize_before_reading_payload() {
    let mut wire = Cursor::new(vec![]);
    write_frame(
        &mut wire,
        &GuestEvent::Output {
            channel: "agent".into(),
            sequence: 1,
            bytes: vec![255, 0, 0xe2, 0x82],
        },
    )
    .unwrap();
    wire.set_position(0);
    match read_frame(&mut wire).unwrap() {
        GuestEvent::Output { bytes, .. } => assert_eq!(bytes, [255, 0, 0xe2, 0x82]),
        _ => panic!("wrong event"),
    }
    let mut oversized = Cursor::new(((MAX_FRAME_BYTES + 1) as u32).to_be_bytes());
    assert!(read_frame::<GuestRequest>(&mut oversized).is_err());
    assert_eq!(oversized.position(), 4);
}

#[test]
fn guest_requests_reject_host_commands_unknown_profiles_and_unknown_fields() {
    for json in [
        r#"{"type":"start","channel":"agent","profile":"codex"}"#,
        r#"{"type":"start","channel":"agent","profile":"fixture","command":"/bin/host"}"#,
        r#"{"type":"input","channel":"agent","request_id":"r","bytes":[],"token":"secret"}"#,
        r#"{"type":"input","channel":"shell","request_id":"r","bytes":[1]}"#,
    ] {
        let mut wire = Vec::from((json.len() as u32).to_be_bytes());
        wire.extend_from_slice(json.as_bytes());
        assert!(read_frame::<GuestRequest>(&mut Cursor::new(wire)).is_err());
    }
    assert!(GuestProfile::registered("unknown").is_err());
}

#[test]
fn guest_fences_reject_zero_epoch_unbounded_ttl_and_revoked_terminal_claims() {
    let fence = |epoch, ttl_millis, terminal_channels| GuestRequest::ControlFence {
        request_id: "fence".into(),
        epoch,
        ttl_millis,
        terminal_channels,
    };
    fence(1, 30000, vec!["agent".into(), "shell".into()])
        .validate()
        .unwrap();
    fence(2, 0, vec![]).validate().unwrap();
    for bad in [
        fence(0, 1, vec![]),
        fence(1, 30001, vec![]),
        fence(2, 0, vec!["shell".into()]),
        fence(1, 30, vec!["shell".into(), "agent".into()]),
    ] {
        assert!(bad.validate().is_err());
    }
}

#[test]
fn polling_survives_a_timeout_after_each_header_and_payload_byte() {
    use std::{
        collections::VecDeque,
        io::{Error, ErrorKind, Read},
    };
    struct Fragmented(VecDeque<u8>, bool);
    impl Read for Fragmented {
        fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
            self.1 = !self.1;
            if self.1 {
                return Err(Error::from(ErrorKind::WouldBlock));
            }
            match self.0.pop_front() {
                Some(byte) => {
                    bytes[0] = byte;
                    Ok(1)
                }
                None => Ok(0),
            }
        }
    }
    let mut wire = vec![];
    for sequence in [1, 2] {
        write_frame(
            &mut wire,
            &GuestEvent::Output {
                channel: "agent".into(),
                sequence,
                bytes: vec![0, 255, 0xe2, 0x82],
            },
        )
        .unwrap();
    }
    let mut source = Fragmented(wire.into(), false);
    let mut reader = FrameReader::<GuestEvent>::default();
    for expected in [1, 2] {
        loop {
            if let Some(event) = reader.poll(&mut source).unwrap() {
                match event {
                    GuestEvent::Output {
                        sequence, bytes, ..
                    } => {
                        assert!(reader.poll(&mut source).unwrap().is_none());
                        assert_eq!(sequence, expected);
                        assert_eq!(bytes, [0, 255, 0xe2, 0x82]);
                    }
                    _ => panic!("wrong event"),
                }
                break;
            }
        }
    }
    assert_eq!(
        reader.poll(&mut source).unwrap_err().kind(),
        ErrorKind::UnexpectedEof
    );
    let mut oversized = Cursor::new(((MAX_FRAME_BYTES + 1) as u32).to_be_bytes());
    assert!(
        FrameReader::<GuestEvent>::default()
            .poll(&mut oversized)
            .is_err()
    );
    assert_eq!(oversized.position(), 4);
}
