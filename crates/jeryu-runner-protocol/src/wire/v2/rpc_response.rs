//! Closed K2 control responses. Results preserve existing JSON shapes.
use super::{
    ControlAck, ControllerLease, SessionSnapshot, SessionStreamEvent, SessionStreamFrame,
    TerminalFrame, header, message_io, positive,
};
use crate::wire::validation::{
    ValidateWire, WireError, WireErrorCode, validate_id, validate_label,
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SessionRpcResponse {
    #[schemars(schema_with = "super::schema::version")]
    pub protocol_version: String,
    #[schemars(schema_with = "super::schema::rpc_response_type")]
    pub message_type: String,
    pub request_id: Option<String>,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<SessionRpcResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<SessionRpcError>,
}
#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(untagged)]
pub enum SessionRpcResult {
    Snapshot(SessionSnapshot),
    Controller(ControllerLease),
    Control(ControlAck),
    Replay(Vec<TerminalFrame>),
    Grant(GrantApplied),
}
#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GrantApplied {
    pub applied: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SessionRpcError {
    pub code: String,
}

impl ValidateWire for SessionRpcResponse {
    fn validate_wire(&self) -> Result<(), WireError> {
        header(
            &self.protocol_version,
            &self.message_type,
            "session-rpc-response",
        )?;
        if let Some(id) = &self.request_id {
            validate_id("request_id", id)?;
        }
        match (&self.result, &self.error, self.ok) {
            (Some(result), None, true) if self.request_id.is_some() => match result {
                SessionRpcResult::Snapshot(snapshot) => {
                    let channel = snapshot.channels.first().ok_or_else(invalid)?;
                    SessionStreamFrame {
                        protocol_version: self.protocol_version.clone(),
                        message_type: "session-stream".into(),
                        request_id: self.request_id.clone().ok_or_else(invalid)?,
                        session_id: snapshot.context.session_id.clone(),
                        generation: snapshot.context.generation,
                        channel_id: channel.channel_id.clone(),
                        payload: SessionStreamEvent::Snapshot {
                            snapshot: snapshot.clone(),
                        },
                    }
                    .validate()
                }
                SessionRpcResult::Controller(controller) => {
                    validate_id("controller_id", &controller.controller_id)?;
                    positive("epoch", controller.epoch)?;
                    positive("next_sequence", controller.next_sequence)?;
                    if !(1..=30).contains(&controller.expires_in_seconds) {
                        return Err(invalid());
                    }
                    Ok(())
                }
                SessionRpcResult::Control(ack) => ack.validate(),
                SessionRpcResult::Replay(frames) => {
                    if frames.len() > 5 {
                        return Err(invalid());
                    }
                    for frame in frames {
                        frame.validate()?;
                    }
                    Ok(())
                }
                SessionRpcResult::Grant(applied) if applied.applied => Ok(()),
                _ => Err(invalid()),
            },
            (None, Some(error), false) => validate_label("error_code", &error.code),
            _ => Err(invalid()),
        }
    }
}
message_io!(SessionRpcResponse);
fn invalid() -> WireError {
    WireError::new(WireErrorCode::ContextMismatch, "rpc_result")
}
