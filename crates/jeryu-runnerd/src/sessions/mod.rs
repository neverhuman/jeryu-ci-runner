//! Managed session service. Every live session starts a verified Firecracker VM;
//! subscribers and command writers never execute a host agent or shell.
mod control;
mod replay;
mod service;
mod state;
#[cfg(test)]
mod tests;
pub use control::ControllerLease;
pub use replay::Subscription;
#[cfg(test)]
pub(crate) use service::stream_test_handle;
pub use service::{SessionHandle, SessionService};
pub use state::{AccessGrant, ChannelSnapshot, RuntimePhase, SessionEvent, SessionSnapshot};

use jeryu_runner_core::{RunnerError, RunnerResult};
fn failed(code: &'static str) -> RunnerError {
    RunnerError::new(code, "managed session operation rejected")
}
