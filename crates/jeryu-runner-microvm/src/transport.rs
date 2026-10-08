//! One bounded reader per session, independent of the command writer. Polling
//! preserves partial messages and checks lease fencing before delivering data.
use jeryu_runner_core::{RunnerError, RunnerResult, receipt::now_ms};
use jeryu_runner_protocol::guest::{FrameReader, GuestEvent};
use std::{
    os::unix::net::UnixStream,
    time::{Duration, Instant},
};

pub struct GuestReader {
    channel: UnixStream,
    expires_at_unix_millis: u64,
    deadline: Instant,
    frames: FrameReader<GuestEvent>,
}

impl GuestReader {
    pub(crate) fn new(channel: UnixStream, expires_at_unix_millis: u64, deadline: Instant) -> Self {
        Self {
            channel,
            expires_at_unix_millis,
            deadline,
            frames: FrameReader::default(),
        }
    }
    pub fn poll(&mut self, timeout: Duration) -> RunnerResult<Option<GuestEvent>> {
        self.ensure_live()?;
        let remaining = self.deadline.saturating_duration_since(Instant::now());
        self.channel.set_read_timeout(Some(
            timeout
                .min(Duration::from_millis(250))
                .min(remaining)
                .max(Duration::from_millis(1)),
        ))?;
        let event = self.frames.poll(&mut self.channel).map_err(|_| {
            RunnerError::new(
                "microvm_guest_transport_failed",
                "guest transport closed or sent an invalid frame",
            )
        })?;
        self.ensure_live()?;
        Ok(event)
    }
    pub fn receive(&mut self) -> RunnerResult<GuestEvent> {
        loop {
            if let Some(event) = self.poll(Duration::from_millis(250))? {
                return Ok(event);
            }
        }
    }
    fn ensure_live(&self) -> RunnerResult<()> {
        if Instant::now() >= self.deadline || now_ms() >= u128::from(self.expires_at_unix_millis) {
            return Err(RunnerError::new(
                "microvm_lease_expired",
                "guest event lease expired",
            ));
        }
        Ok(())
    }
}
