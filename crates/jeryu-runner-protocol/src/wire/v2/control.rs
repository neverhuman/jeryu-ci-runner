use super::{MAX_PROMPT_BYTES, MAX_TERMINAL_BYTES, SessionContext, header, message_io, positive};
use crate::wire::validation::{
    ValidateWire, WireError, WireErrorCode, validate_id, validate_label, validate_text,
};
use serde::{Deserialize, Serialize};

/// Input and process controls are interpreted inside the guest. Prompt requires
/// a native provider adapter; PTY input is never acknowledged as a prompt.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(tag = "action", rename_all = "kebab-case", deny_unknown_fields)]
pub enum ControlCommand {
    Input { bytes: Vec<u8> },
    Prompt { text: String },
    Resize { rows: u16, cols: u16 },
    Interrupt,
    Stop,
}

impl ControlCommand {
    fn validate(&self) -> Result<(), WireError> {
        match self {
            Self::Input { bytes } if bytes.is_empty() || bytes.len() > MAX_TERMINAL_BYTES => {
                Err(WireError::new(WireErrorCode::InvalidCollection, "input"))
            }
            Self::Prompt { text } => {
                validate_text("prompt", text, MAX_PROMPT_BYTES)?;
                if text.is_empty() {
                    return Err(WireError::new(WireErrorCode::InvalidField, "prompt"));
                }
                Ok(())
            }
            Self::Resize { rows, cols }
                if *rows == 0 || *cols == 0 || *rows > 4096 || *cols > 4096 =>
            {
                Err(WireError::new(WireErrorCode::InvalidField, "terminal_size"))
            }
            _ => Ok(()),
        }
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ControlRequest {
    #[schemars(schema_with = "super::schema::version")]
    pub protocol_version: String,
    #[schemars(schema_with = "super::schema::control_type")]
    pub message_type: String,
    pub context: SessionContext,
    #[schemars(schema_with = "super::schema::id")]
    pub request_id: String,
    #[schemars(schema_with = "super::schema::label")]
    pub channel_id: String,
    #[schemars(schema_with = "super::schema::id")]
    pub controller_id: String,
    #[schemars(range(min = 1))]
    pub control_lease_epoch: u64,
    /// Strictly increasing within a control lease. Fences replay after bounded
    /// acknowledgement history has been evicted.
    #[schemars(range(min = 1))]
    pub control_sequence: u64,
    pub command: ControlCommand,
}

impl ValidateWire for ControlRequest {
    fn validate_wire(&self) -> Result<(), WireError> {
        header(
            &self.protocol_version,
            &self.message_type,
            "session-control",
        )?;
        self.context.validate_wire()?;
        validate_id("request_id", &self.request_id)?;
        validate_label("channel_id", &self.channel_id)?;
        validate_id("controller_id", &self.controller_id)?;
        positive("control_lease_epoch", self.control_lease_epoch)?;
        positive("control_sequence", self.control_sequence)?;
        self.command.validate()
    }
}
message_io!(ControlRequest);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum ControlState {
    Accepted,
    Applied,
    Rejected,
    Interrupted,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ControlAck {
    #[schemars(schema_with = "super::schema::version")]
    pub protocol_version: String,
    #[schemars(schema_with = "super::schema::ack_type")]
    pub message_type: String,
    pub context: SessionContext,
    #[schemars(schema_with = "super::schema::id")]
    pub request_id: String,
    #[schemars(schema_with = "super::schema::label")]
    pub channel_id: String,
    pub state: ControlState,
    /// Machine-readable reason; never contains a rejected prompt or input.
    #[schemars(schema_with = "super::schema::label")]
    pub reason: String,
}

impl ControlAck {
    pub fn validate_for(&self, request: &ControlRequest) -> Result<(), WireError> {
        self.validate()?;
        request.validate()?;
        if self.context != request.context
            || self.request_id != request.request_id
            || self.channel_id != request.channel_id
        {
            return Err(WireError::new(
                WireErrorCode::ContextMismatch,
                "control_ack",
            ));
        }
        Ok(())
    }
}

impl ValidateWire for ControlAck {
    fn validate_wire(&self) -> Result<(), WireError> {
        header(
            &self.protocol_version,
            &self.message_type,
            "session-control-ack",
        )?;
        self.context.validate_wire()?;
        validate_id("request_id", &self.request_id)?;
        validate_label("channel_id", &self.channel_id)?;
        validate_label("reason", &self.reason)
    }
}
message_io!(ControlAck);

/// Raw terminal bytes with generation-aware replay. A gap frame carries the
/// earliest available cursor in `sequence` and no data. Viewers resync from it.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TerminalFrame {
    #[schemars(schema_with = "super::schema::version")]
    pub protocol_version: String,
    #[schemars(schema_with = "super::schema::terminal_type")]
    pub message_type: String,
    #[schemars(schema_with = "super::schema::id")]
    pub session_id: String,
    #[schemars(range(min = 1))]
    pub generation: u64,
    #[schemars(schema_with = "super::schema::id")]
    pub run_id: String,
    #[schemars(schema_with = "super::schema::label")]
    pub channel_id: String,
    #[schemars(range(min = 1))]
    pub sequence: u64,
    pub gap: bool,
    #[schemars(length(max = super::MAX_TERMINAL_BYTES))]
    pub bytes: Vec<u8>,
}

impl ValidateWire for TerminalFrame {
    fn validate_wire(&self) -> Result<(), WireError> {
        header(
            &self.protocol_version,
            &self.message_type,
            "session-terminal",
        )?;
        validate_id("session_id", &self.session_id)?;
        positive("generation", self.generation)?;
        validate_id("run_id", &self.run_id)?;
        validate_label("channel_id", &self.channel_id)?;
        positive("sequence", self.sequence)?;
        if self.bytes.len() > MAX_TERMINAL_BYTES
            || (self.gap && !self.bytes.is_empty())
            || (!self.gap && self.bytes.is_empty())
        {
            return Err(WireError::new(
                WireErrorCode::InvalidCollection,
                "terminal_bytes",
            ));
        }
        Ok(())
    }
}
message_io!(TerminalFrame);

impl_redacted_debug!(ControlCommand, ControlRequest, TerminalFrame);
