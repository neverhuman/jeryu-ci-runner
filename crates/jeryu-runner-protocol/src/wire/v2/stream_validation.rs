use super::{SessionStreamEvent, SessionStreamFrame, header, message_io, positive};
use crate::wire::validation::{
    ValidateWire, WireError, WireErrorCode, validate_id, validate_label,
};

impl ValidateWire for SessionStreamFrame {
    fn validate_wire(&self) -> Result<(), WireError> {
        header(&self.protocol_version, &self.message_type, "session-stream")?;
        validate_id("request_id", &self.request_id)?;
        validate_id("session_id", &self.session_id)?;
        positive("generation", self.generation)?;
        validate_label("channel_id", &self.channel_id)?;
        let matches = match &self.payload {
            SessionStreamEvent::Terminal { frame } => {
                frame.validate()?;
                frame.session_id == self.session_id
                    && frame.generation == self.generation
                    && frame.channel_id == self.channel_id
            }
            SessionStreamEvent::Control { acknowledgement } => {
                acknowledgement.validate()?;
                acknowledgement.context.session_id == self.session_id
                    && acknowledgement.context.generation == self.generation
                    && acknowledgement.channel_id == self.channel_id
            }
            SessionStreamEvent::Snapshot { snapshot } => {
                snapshot.context.validate_wire()?;
                if let Some(workspace) = &snapshot.workspace {
                    workspace.validate()?;
                }
                if let Some(checkpoint) = &snapshot.checkpoint {
                    checkpoint.validate()?;
                }
                if snapshot.channels.len() > 2
                    || snapshot.reason.as_ref().is_some_and(|s| s.len() > 128)
                {
                    return Err(invalid());
                }
                for (index, channel) in snapshot.channels.iter().enumerate() {
                    validate_label("channel_id", &channel.channel_id)?;
                    if snapshot.channels[..index]
                        .iter()
                        .any(|c| c.channel_id == channel.channel_id)
                        || channel.earliest_cursor > channel.cursor.saturating_add(1)
                    {
                        return Err(invalid());
                    }
                }
                snapshot.context.session_id == self.session_id
                    && snapshot.context.generation == self.generation
                    && snapshot
                        .channels
                        .iter()
                        .any(|c| c.channel_id == self.channel_id)
            }
            SessionStreamEvent::End { reason } => {
                validate_label("reason", reason)?;
                true
            }
            SessionStreamEvent::Heartbeat => true,
        };
        if !matches {
            return Err(invalid());
        }
        Ok(())
    }
}
message_io!(SessionStreamFrame);
fn invalid() -> WireError {
    WireError::new(WireErrorCode::ContextMismatch, "stream_binding")
}
