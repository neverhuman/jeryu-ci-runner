use super::{failed, state::SessionEvent};
use jeryu_runner_core::RunnerResult;
use jeryu_runner_protocol::wire::v2::{TERMINAL_TAIL_BYTES, TerminalFrame};
use std::{
    collections::VecDeque,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{Receiver, SyncSender},
    },
    time::Duration,
};

pub(super) struct Tail {
    frames: VecDeque<TerminalFrame>,
    bytes: usize,
    pub cursor: u64,
}
impl Tail {
    pub fn new() -> Self {
        Self {
            frames: VecDeque::new(),
            bytes: 0,
            cursor: 0,
        }
    }
    pub fn push(&mut self, mut frame: TerminalFrame) -> TerminalFrame {
        self.cursor += 1;
        frame.sequence = self.cursor;
        self.bytes += frame.bytes.len();
        self.frames.push_back(frame.clone());
        while self.bytes > TERMINAL_TAIL_BYTES || self.frames.len() > 8192 {
            if let Some(frame) = self.frames.pop_front() {
                self.bytes -= frame.bytes.len();
            }
        }
        frame
    }
    pub fn earliest(&self) -> u64 {
        self.frames
            .front()
            .map_or(self.cursor + 1, |frame| frame.sequence)
    }
    pub fn after(&self, cursor: u64, limit: usize) -> Vec<TerminalFrame> {
        self.frames
            .iter()
            .filter(|frame| frame.sequence > cursor)
            .take(limit)
            .cloned()
            .collect()
    }
}

pub(super) struct Viewer {
    pub actor: String,
    pub channel: String,
    pub send: SyncSender<SessionEvent>,
    pub revoked: Arc<AtomicBool>,
    pub gap: Arc<AtomicU64>,
}

pub struct Subscription {
    pub(super) receive: Receiver<SessionEvent>,
    pub(super) revoked: Arc<AtomicBool>,
    pub(super) gap: Arc<AtomicU64>,
    pub(super) template: TerminalFrame,
}
impl Subscription {
    /// Revocation is checked before queued data. A slow viewer gets a gap and
    /// replays from its cursor; the producer never waits for a viewer queue.
    pub fn next(&self, timeout: Duration) -> RunnerResult<Option<SessionEvent>> {
        if self.revoked.load(Ordering::Acquire) {
            return Err(failed("session_access_revoked"));
        }
        let cursor = self.gap.swap(0, Ordering::AcqRel);
        if cursor != 0 {
            while self.receive.try_recv().is_ok() {}
            let mut frame = self.template.clone();
            frame.sequence = cursor;
            return Ok(Some(SessionEvent::Terminal(frame)));
        }
        let event = match self.receive.recv_timeout(timeout) {
            Ok(event) => Some(event),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => None,
            Err(_) => return Err(failed("session_subscription_closed")),
        };
        if self.revoked.load(Ordering::Acquire) {
            return Err(failed("session_access_revoked"));
        }
        Ok(event)
    }
}
impl Drop for Subscription {
    fn drop(&mut self) {
        self.revoked.store(true, Ordering::Release);
    }
}
