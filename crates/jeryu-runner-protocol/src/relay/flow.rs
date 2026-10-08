//! Bounded counters, never request/response body storage. Consumers separately
//! bind these to a request id, direction, lease and cancellation/idle lifetime.
use super::*;
use std::collections::VecDeque;
const INVALID: RelayErrorCode = RelayErrorCode::RelayStreamInvalid;

#[derive(Default, Debug)]
pub struct BodySequence {
    last: u64,
    ended: bool,
}
impl BodySequence {
    pub fn body(&mut self, seq: u64) -> Result<(), RelayErrorCode> {
        if self.ended || self.last.checked_add(1) != Some(seq) {
            return Err(INVALID);
        }
        self.last = seq;
        Ok(())
    }
    pub fn end(&mut self, seq_end: u64) -> Result<(), RelayErrorCode> {
        if self.ended || self.last != seq_end {
            return Err(INVALID);
        }
        self.ended = true;
        Ok(())
    }
}

#[derive(Default, Debug)]
pub struct SendWindow {
    last: u64,
    acknowledged: u64,
    bytes: usize,
    // Length only, two bytes per entry. At most WINDOW_BYTES one-byte chunks:
    // metadata is bounded too, not an unbounded map beside a small body queue.
    lengths: VecDeque<u16>,
}
impl SendWindow {
    /// False is backpressure. Nothing is mutated and the caller must retain
    /// the exact unsent frame for retry after an acknowledgement.
    pub fn reserve(&mut self, seq: u64, bytes: usize) -> Result<bool, RelayErrorCode> {
        if self.last.checked_add(1) != Some(seq) || !(1..=MAX_BODY_BYTES).contains(&bytes) {
            return Err(INVALID);
        }
        if bytes > WINDOW_BYTES - self.bytes {
            return Ok(false);
        }
        self.lengths.push_back(bytes as u16);
        self.bytes += bytes;
        self.last = seq;
        Ok(true)
    }
    pub fn acknowledge(&mut self, through_seq: u64) -> Result<(), RelayErrorCode> {
        if through_seq == 0 || through_seq < self.acknowledged || through_seq > self.last {
            return Err(INVALID);
        }
        let count = usize::try_from(through_seq - self.acknowledged).map_err(|_| INVALID)?;
        if count > self.lengths.len() {
            return Err(INVALID);
        }
        for _ in 0..count {
            self.bytes -= usize::from(self.lengths.pop_front().ok_or(INVALID)?);
        }
        self.acknowledged = through_seq;
        Ok(())
    }
    pub fn pending_bytes(&self) -> usize {
        self.bytes
    }
}
