//! Closed HTTPS/mTLS requests from the authorized control-plane relay.
use super::{ControlRequest, SessionLease, header, message_io, positive};
use crate::wire::validation::{
    ValidateWire, WireError, WireErrorCode, validate_id, validate_label,
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum SessionGrant {
    Viewer,
    Controller,
}

#[derive(Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SessionRpcRequest {
    #[schemars(schema_with = "super::schema::version")]
    pub protocol_version: String,
    #[schemars(schema_with = "super::schema::rpc_type")]
    pub message_type: String,
    #[schemars(schema_with = "super::schema::id")]
    pub request_id: String,
    pub operation: SessionRpcOperation,
}
#[derive(Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(tag = "action", rename_all = "kebab-case", deny_unknown_fields)]
pub enum SessionRpcOperation {
    Start {
        lease: Box<SessionLease>,
    },
    Snapshot {
        actor: String,
        session_id: String,
        generation: u64,
    },
    AcquireControl {
        actor: String,
        /// Assigned by the control plane per client attachment, not per user.
        controller_id: String,
        terminal_channels: Vec<String>,
        session_id: String,
        generation: u64,
        takeover: bool,
    },
    Screen {
        actor: String,
        session_id: String,
        generation: u64,
        channel_id: String,
    },
    Control {
        actor: String,
        request: Box<ControlRequest>,
    },
    Acknowledgement {
        actor: String,
        session_id: String,
        generation: u64,
        control_request_id: String,
    },
    Replay {
        actor: String,
        session_id: String,
        generation: u64,
        channel_id: String,
        cursor: u64,
        #[schemars(range(min = 1, max = 4))]
        limit: usize,
    },
    Grant {
        actor: String,
        session_id: String,
        generation: u64,
        subject: String,
        grant: Option<SessionGrant>,
    },
}
impl ValidateWire for SessionRpcRequest {
    fn validate_wire(&self) -> Result<(), WireError> {
        header(&self.protocol_version, &self.message_type, "session-rpc")?;
        validate_id("request_id", &self.request_id)?;
        use SessionRpcOperation::*;
        match &self.operation {
            Start { lease } => lease.validate_wire(),
            Control { actor, request } => {
                validate_id("actor", actor)?;
                request.validate_wire()
            }
            Snapshot {
                actor,
                session_id,
                generation,
            }
            | AcquireControl {
                actor,
                session_id,
                generation,
                ..
            }
            | Screen {
                actor,
                session_id,
                generation,
                ..
            }
            | Acknowledgement {
                actor,
                session_id,
                generation,
                ..
            }
            | Replay {
                actor,
                session_id,
                generation,
                ..
            }
            | Grant {
                actor,
                session_id,
                generation,
                ..
            } => {
                validate_id("actor", actor)?;
                validate_id("session_id", session_id)?;
                positive("generation", *generation)?;
                match &self.operation {
                    AcquireControl {
                        controller_id,
                        terminal_channels,
                        ..
                    } => {
                        validate_id("controller_id", controller_id)?;
                        super::validate_terminal_channels(terminal_channels)
                    }
                    Screen { channel_id, .. } => validate_label("channel_id", channel_id),
                    Acknowledgement {
                        control_request_id, ..
                    } => validate_id("control_request_id", control_request_id),
                    Grant { subject, .. } => validate_id("subject", subject),
                    Replay {
                        channel_id, limit, ..
                    } => {
                        validate_label("channel_id", channel_id)?;
                        if !(1..=4).contains(limit) {
                            return Err(WireError::new(
                                WireErrorCode::InvalidCollection,
                                "replay_limit",
                            ));
                        }
                        Ok(())
                    }
                    _ => Ok(()),
                }
            }
        }
    }
}
message_io!(SessionRpcRequest);
impl_redacted_debug!(SessionRpcRequest, SessionRpcOperation);
