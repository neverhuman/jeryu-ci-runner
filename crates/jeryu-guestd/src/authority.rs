//! The fence and every PTY operation share one lock. All writes are nonblocking.
use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

#[derive(Default)]
pub struct Authority {
    epoch: u64,
    expires: Option<Instant>,
    terminals: Vec<String>,
}
pub type SharedAuthority = Arc<Mutex<Authority>>;
impl Authority {
    pub fn fence(
        &mut self,
        epoch: u64,
        ttl_millis: u32,
        terminals: Vec<String>,
    ) -> std::io::Result<()> {
        if epoch < self.epoch || epoch == 0 || (epoch == self.epoch && self.expires.is_none()) {
            return Err(std::io::Error::other("guest_control_fence_invalid"));
        }
        self.epoch = epoch;
        self.expires =
            (ttl_millis > 0).then(|| Instant::now() + Duration::from_millis(ttl_millis.into()));
        self.terminals = terminals;
        Ok(())
    }
    pub fn permits(&self, epoch: u64) -> bool {
        self.epoch == epoch && self.expires.is_some_and(|until| Instant::now() < until)
    }
    pub fn terminal(&self, channel: &str) -> bool {
        self.permits(self.epoch) && self.terminals.iter().any(|id| id == channel)
    }
}
