//! Closed managed-session contracts. V1 CI messages retain their existing shape.
//! Authentication (including mandatory mTLS) belongs to the transport; these
//! bodies contain neither runner credentials nor provider credentials.

mod checkpoint;
mod connection;
mod control;
mod image;
mod interfaces;
mod rpc;
mod rpc_response;
mod runtime;
mod schema;
mod screen;
mod session;
mod signature;
mod stream_validation;
mod workspace;

pub use checkpoint::{CheckpointFormat, CheckpointManifest, CheckpointReference};
pub use connection::{ConnectionBinding, ConnectionMode, Provider};
pub use control::{ControlAck, ControlCommand, ControlRequest, ControlState, TerminalFrame};
pub use image::{RuntimeImageClass, RuntimeProfile};
pub use interfaces::*;
pub use rpc::{SessionGrant, SessionRpcOperation, SessionRpcRequest};
pub use rpc_response::{GrantApplied, SessionRpcError, SessionRpcResponse, SessionRpcResult};
pub use runtime::{
    ArtifactIdentity, GitLimits, RuntimeArchitecture, RuntimeManifest, SessionResources,
};
pub use schema::schema;
pub use screen::{ScreenSnapshot, TerminalScreen};
pub use session::{ManagedPurpose, SessionContext, SessionLease, runtime_digest};
pub use workspace::{WorkspaceReady, WorkspaceSource, WorkspaceSyncState};

pub const PROTOCOL_VERSION: &str = "jeryu.runner.v2.1";
pub const FIRECRACKER_VERSION: &str = "1.17.0";
pub const GUEST_PROTOCOL_VERSION: &str = "jeryu.guest.v2";
pub const MAX_TERMINAL_BYTES: usize = 32_768;
pub const MAX_PROMPT_BYTES: usize = 32_768;
pub const TERMINAL_TAIL_BYTES: usize = 20 * 1024 * 1024;

use super::validation::{WireError, WireErrorCode};

fn header(version: &str, actual: &str, expected: &'static str) -> Result<(), WireError> {
    if version != PROTOCOL_VERSION || actual != expected {
        return Err(WireError::new(
            WireErrorCode::InvalidProtocol,
            "protocol_version",
        ));
    }
    Ok(())
}

fn positive(field: &'static str, value: u64) -> Result<(), WireError> {
    if value == 0 {
        return Err(WireError::new(WireErrorCode::InvalidField, field));
    }
    Ok(())
}

macro_rules! message_io {
    ($name:ty) => {
        impl $name {
            pub fn validate(&self) -> Result<(), crate::wire::WireError> {
                crate::wire::validation::ValidateWire::validate_wire(self)
            }
            pub fn from_json(bytes: &[u8]) -> Result<Self, crate::wire::WireError> {
                crate::wire::validation::decode_message(bytes)
            }
            pub fn to_json(&self) -> Result<Vec<u8>, crate::wire::WireError> {
                crate::wire::validation::encode_message(self)
            }
        }
    };
}
pub(crate) use message_io;
