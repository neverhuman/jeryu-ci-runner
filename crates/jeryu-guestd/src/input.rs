//! Bounded asynchronous PTY writes. Applied acknowledgements are emitted only
//! after every byte has reached the PTY, never when merely queued.
use crate::emit;
use jeryu_runner_protocol::guest::GuestEvent;
use std::{
    fs::File,
    io::Write,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender},
    },
    time::Duration,
};

pub struct Input {
    pub request_id: String,
    pub bytes: Vec<u8>,
}

pub fn start(
    mut master: File,
    writer: Arc<Mutex<File>>,
    finished: Arc<AtomicBool>,
) -> SyncSender<Input> {
    let (send, receive) = mpsc::sync_channel::<Input>(8);
    std::thread::spawn(move || {
        while !finished.load(Ordering::Acquire) {
            let input = match receive.recv_timeout(Duration::from_millis(100)) {
                Ok(input) => input,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            };
            let offset = deliver(&mut master, &input.bytes, &finished);
            let applied = offset == input.bytes.len();
            let reason = if applied {
                "applied"
            } else if offset > 0 {
                "channel_closed_after_partial_input"
            } else {
                "input_unavailable"
            };
            if emit(
                &writer,
                &GuestEvent::Ack {
                    request_id: input.request_id,
                    applied,
                    reason: reason.into(),
                },
            )
            .is_err()
            {
                break;
            }
        }
    });
    send
}

fn deliver(master: &mut impl Write, bytes: &[u8], finished: &AtomicBool) -> usize {
    let mut offset = 0;
    // A slow PTY applies backpressure to this bounded writer. It cannot silently
    // lose the tail at a timer boundary; stop/exit still cancels the worker.
    while offset < bytes.len() && !finished.load(Ordering::Acquire) {
        match master.write(&bytes[offset..]) {
            Ok(0) => break,
            Ok(size) => offset += size,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(5))
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
    offset
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    struct SlowWriter {
        ready: Instant,
        bytes: Vec<u8>,
    }
    impl Write for SlowWriter {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if Instant::now() < self.ready {
                return Err(std::io::ErrorKind::WouldBlock.into());
            }
            let count = bytes.len().min(7);
            self.bytes.extend_from_slice(&bytes[..count]);
            Ok(count)
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    #[test]
    fn a_pty_blocked_longer_than_one_second_preserves_all_input_bytes() {
        let bytes = [0, 255, 0x1b, b'[', b'3', b'1', b'm'].repeat(50);
        let mut writer = SlowWriter {
            ready: Instant::now() + Duration::from_millis(1200),
            bytes: vec![],
        };
        assert_eq!(
            deliver(&mut writer, &bytes, &AtomicBool::new(false)),
            bytes.len()
        );
        assert_eq!(writer.bytes, bytes);
        let stopped = AtomicBool::new(true);
        assert_eq!(deliver(&mut writer, b"must-not-write", &stopped), 0);
        assert_eq!(writer.bytes, bytes);
    }
}
