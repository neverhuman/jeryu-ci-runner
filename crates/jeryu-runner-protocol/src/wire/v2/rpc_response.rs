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
    Screen(super::TerminalScreen),
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
                    controller.context.validate()?;
                    validate_id("actor", &controller.actor)?;
                    validate_id("controller_id", &controller.controller_id)?;
                    super::validate_terminal_channels(&controller.terminal_channels)?;
                    positive("epoch", controller.epoch)?;
                    positive("next_sequence", controller.next_sequence)?;
                    if !(1..=30).contains(&controller.expires_in_seconds) {
                        return Err(invalid());
                    }
                    Ok(())
                }
                SessionRpcResult::Control(ack) => ack.validate(),
                SessionRpcResult::Screen(screen) => screen.validate(),
                SessionRpcResult::Replay(frames) => {
                    if frames.len() > 5 || frames.iter().filter(|f| !f.gap).count() > 4 {
                        return Err(invalid());
                    }
                    for (index, frame) in frames.iter().enumerate() {
                        frame.validate()?;
                        let first = &frames[0];
                        if (
                            frame.session_id.as_str(),
                            frame.generation,
                            frame.run_id.as_str(),
                            frame.channel_id.as_str(),
                        ) != (
                            first.session_id.as_str(),
                            first.generation,
                            first.run_id.as_str(),
                            first.channel_id.as_str(),
                        ) || (frame.gap && index != 0)
                        {
                            return Err(invalid());
                        }
                        if let Some(previous) = index.checked_sub(1).map(|i| &frames[i])
                            && Some(frame.sequence)
                                != if previous.gap {
                                    Some(previous.sequence)
                                } else {
                                    previous.sequence.checked_add(1)
                                }
                        {
                            return Err(invalid());
                        }
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

impl SessionRpcResponse {
    /// Clients and services bind a response to the signed context they expect.
    /// This validates identity; it never grants the actor view/control rights.
    pub fn validate_for(
        &self,
        request: &super::SessionRpcRequest,
        context: &super::SessionContext,
    ) -> Result<(), WireError> {
        use super::SessionRpcOperation as Op;
        self.validate()?;
        request.validate()?;
        context.validate()?;
        if self
            .request_id
            .as_deref()
            .is_some_and(|id| id != request.request_id)
        {
            return Err(invalid());
        }
        let target = match &request.operation {
            Op::Start { lease } => {
                if lease.context != *context {
                    return Err(invalid());
                }
                (&context.session_id, context.generation)
            }
            Op::Control { request, .. } => {
                if request.context != *context {
                    return Err(invalid());
                }
                (&context.session_id, context.generation)
            }
            Op::Snapshot {
                session_id,
                generation,
                ..
            }
            | Op::AcquireControl {
                session_id,
                generation,
                ..
            }
            | Op::Screen {
                session_id,
                generation,
                ..
            }
            | Op::Acknowledgement {
                session_id,
                generation,
                ..
            }
            | Op::Replay {
                session_id,
                generation,
                ..
            }
            | Op::Grant {
                session_id,
                generation,
                ..
            } => (session_id, *generation),
        };
        if target != (&context.session_id, context.generation) {
            return Err(invalid());
        }
        let Some(result) = &self.result else {
            return Ok(());
        };
        match (&request.operation, result) {
            (Op::Start { .. } | Op::Snapshot { .. }, SessionRpcResult::Snapshot(snapshot))
                if snapshot.context == *context =>
            {
                Ok(())
            }
            (
                Op::AcquireControl {
                    actor,
                    controller_id,
                    terminal_channels,
                    ..
                },
                SessionRpcResult::Controller(lease),
            ) if lease.context == *context
                && lease.actor == *actor
                && lease.controller_id == *controller_id
                && lease.terminal_channels == *terminal_channels =>
            {
                Ok(())
            }
            (Op::Screen { channel_id, .. }, SessionRpcResult::Screen(screen))
                if screen.context == *context && screen.channel_id == *channel_id =>
            {
                Ok(())
            }
            (Op::Control { request, .. }, SessionRpcResult::Control(ack)) => {
                ack.validate_for(request)
            }
            (
                Op::Acknowledgement {
                    control_request_id, ..
                },
                SessionRpcResult::Control(ack),
            ) if ack.context == *context && ack.request_id == *control_request_id => Ok(()),
            (
                Op::Replay {
                    channel_id, limit, ..
                },
                SessionRpcResult::Replay(frames),
            ) => {
                if frames.iter().filter(|f| !f.gap).count() > *limit
                    || frames.iter().any(|f| {
                        f.session_id != context.session_id
                            || f.generation != context.generation
                            || f.run_id != context.run_id
                            || f.channel_id != *channel_id
                    })
                {
                    return Err(invalid());
                }
                Ok(())
            }
            (Op::Grant { .. }, SessionRpcResult::Grant(_)) => Ok(()),
            _ => Err(invalid()),
        }
    }
}
fn invalid() -> WireError {
    WireError::new(WireErrorCode::ContextMismatch, "rpc_result")
}
