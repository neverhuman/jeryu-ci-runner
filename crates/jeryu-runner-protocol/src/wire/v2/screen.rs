//! A bounded headless screen accompanies, but never replaces, raw PTY replay.
use super::{SessionContext, header, message_io};
use crate::wire::validation::{ValidateWire, WireError, WireErrorCode, validate_label};
use serde::{Deserialize, Serialize};

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ScreenSnapshot {
    /// Last raw output sequence included, zero before the first output.
    pub sequence: u64,
    #[schemars(range(min = 1, max = 200))]
    pub rows: u16,
    #[schemars(range(min = 1, max = 400))]
    pub cols: u16,
    pub cursor_row: u16,
    pub cursor_col: u16,
    /// At most 64 KiB of UTF-8; no scrollback, OSC clipboard or hyperlinks.
    #[schemars(length(max = 65536))]
    pub text: String,
    pub truncated: bool,
}
impl ScreenSnapshot {
    pub fn validate(&self) -> Result<(), WireError> {
        if !(1..=200).contains(&self.rows)
            || !(1..=400).contains(&self.cols)
            || self.cursor_row >= self.rows
            || self.cursor_col >= self.cols
            || self.text.len() > 65536
        {
            return Err(WireError::new(WireErrorCode::InvalidField, "screen"));
        }
        Ok(())
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TerminalScreen {
    #[schemars(schema_with = "super::schema::version")]
    pub protocol_version: String,
    pub message_type: String,
    pub context: SessionContext,
    pub channel_id: String,
    pub screen: ScreenSnapshot,
}
impl ValidateWire for TerminalScreen {
    fn validate_wire(&self) -> Result<(), WireError> {
        header(
            &self.protocol_version,
            &self.message_type,
            "terminal-screen",
        )?;
        self.context.validate_wire()?;
        validate_label("channel_id", &self.channel_id)?;
        self.screen.validate()
    }
}
message_io!(TerminalScreen);
impl_redacted_debug!(ScreenSnapshot, TerminalScreen);
