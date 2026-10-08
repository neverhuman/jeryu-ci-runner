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
    time::{Duration, Instant},
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
            let mut offset = 0;
            let deadline = Instant::now() + Duration::from_secs(1);
            while offset < input.bytes.len()
                && Instant::now() < deadline
                && !finished.load(Ordering::Acquire)
            {
                match master.write(&input.bytes[offset..]) {
                    Ok(0) => break,
                    Ok(size) => offset += size,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(5))
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }
            let applied = offset == input.bytes.len();
            let reason = if applied {
                "applied"
            } else if offset > 0 {
                "partial_input"
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
