//! Length-delimited, bounded messages on the dedicated guest execution channel.
//! No host paths, host commands, or host services are exposed on this channel.
use crate::wire::v2::{GUEST_PROTOCOL_VERSION, MAX_TERMINAL_BYTES, SessionLease, WorkspaceReady};
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
mod reader;
pub use reader::FrameReader;

pub const EXECUTION_PORT: u32 = 1024;
pub const MAX_FRAME_BYTES: usize = 256 * 1024;

#[derive(Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(tag = "type", rename_all = "kebab-case", deny_unknown_fields)]
pub enum GuestRequest {
    Bind {
        lease: Box<SessionLease>,
        challenge: String,
    },
    Start {
        channel: String,
        profile: GuestProfile,
    },
    Input {
        channel: String,
        request_id: String,
        control_epoch: u64,
        bytes: Vec<u8>,
    },
    Resize {
        channel: String,
        request_id: String,
        control_epoch: u64,
        rows: u16,
        cols: u16,
    },
    Interrupt {
        channel: String,
        request_id: String,
        control_epoch: u64,
    },
    ControlFence {
        request_id: String,
        epoch: u64,
        /// Zero revokes. Relative guest expiry may precede the node expiry.
        #[schemars(range(max = 30000))]
        ttl_millis: u32,
        terminal_channels: Vec<String>,
    },
    Stop {
        request_id: String,
    },
    Freeze {
        request_id: String,
    },
}

/// Only qualified image entrypoints are selectable. Provider profiles are added
/// after their native adapters and access-only authentication qualify.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum GuestProfile {
    Fixture,
    Shell,
}

impl GuestProfile {
    pub fn registered(id: &str) -> std::io::Result<Self> {
        match id {
            "fixture" => Ok(Self::Fixture),
            "shell" => Ok(Self::Shell),
            _ => Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "unknown_agent_profile",
            )),
        }
    }
}

#[derive(Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(tag = "type", rename_all = "kebab-case", deny_unknown_fields)]
pub enum GuestEvent {
    Ready {
        #[schemars(schema_with = "guest_version_schema")]
        protocol_version: String,
        challenge: String,
        session_id: String,
        generation: u64,
        run_id: String,
        workspace: Option<WorkspaceReady>,
    },
    Started {
        channel: String,
    },
    Output {
        channel: String,
        sequence: u64,
        bytes: Vec<u8>,
    },
    Exited {
        channel: String,
        exit_code: Option<i32>,
    },
    Ack {
        request_id: String,
        applied: bool,
        reason: String,
    },
    ControlFenced {
        request_id: String,
        epoch: u64,
    },
    Screen {
        channel: String,
        screen: crate::wire::v2::ScreenSnapshot,
    },
    Stopped,
    Frozen {
        request_id: String,
        workspace: Option<WorkspaceReady>,
    },
    Error {
        code: String,
    },
}

#[derive(schemars::JsonSchema, Serialize, Deserialize)]
#[serde(untagged)]
enum GuestMessageSchema {
    Request(GuestRequest),
    Event(GuestEvent),
}
pub fn schema() -> schemars::Schema {
    schemars::schema_for!(GuestMessageSchema)
}
fn guest_version_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
    schemars::json_schema!({"type":"string", "const":GUEST_PROTOCOL_VERSION})
}

impl GuestRequest {
    pub fn validate(&self) -> std::io::Result<()> {
        match self {
            Self::Bind { lease, challenge } => {
                lease.validate().map_err(|_| invalid())?;
                challenge_valid(challenge)?;
            }
            Self::Start { channel, .. } => name(channel)?,
            Self::Input {
                channel,
                request_id,
                control_epoch,
                bytes,
            } => {
                name(channel)?;
                name(request_id)?;
                epoch_valid(*control_epoch)?;
                if bytes.is_empty() || bytes.len() > MAX_TERMINAL_BYTES {
                    return Err(invalid());
                }
            }
            Self::Resize {
                channel,
                request_id,
                control_epoch,
                rows,
                cols,
            } => {
                name(channel)?;
                name(request_id)?;
                epoch_valid(*control_epoch)?;
                if *rows == 0 || *cols == 0 || *rows > 4096 || *cols > 4096 {
                    return Err(invalid());
                }
            }
            Self::Interrupt {
                channel,
                request_id,
                control_epoch,
            } => {
                name(channel)?;
                name(request_id)?;
                epoch_valid(*control_epoch)?;
            }
            Self::ControlFence {
                request_id,
                epoch,
                ttl_millis,
                terminal_channels,
            } => {
                name(request_id)?;
                epoch_valid(*epoch)?;
                if *ttl_millis > 30000 || (*ttl_millis == 0 && !terminal_channels.is_empty()) {
                    return Err(invalid());
                }
                crate::wire::v2::validate_terminal_channels(terminal_channels)
                    .map_err(|_| invalid())?;
            }
            Self::Stop { request_id } | Self::Freeze { request_id } => name(request_id)?,
        }
        Ok(())
    }
}

impl GuestEvent {
    pub fn validate(&self) -> std::io::Result<()> {
        match self {
            Self::Ready {
                protocol_version,
                challenge,
                session_id,
                generation,
                run_id,
                workspace,
            } => {
                if protocol_version != GUEST_PROTOCOL_VERSION || *generation == 0 {
                    return Err(invalid());
                }
                challenge_valid(challenge)?;
                name(session_id)?;
                name(run_id)?;
                if let Some(workspace) = workspace {
                    workspace.validate().map_err(|_| invalid())?;
                }
            }
            Self::Started { channel } | Self::Exited { channel, .. } => name(channel)?,
            Self::Output {
                channel,
                sequence,
                bytes,
            } => {
                name(channel)?;
                if *sequence == 0 || bytes.is_empty() || bytes.len() > MAX_TERMINAL_BYTES {
                    return Err(invalid());
                }
            }
            Self::Ack {
                request_id, reason, ..
            } => {
                name(request_id)?;
                name(reason)?;
            }
            Self::Error { code } => name(code)?,
            Self::ControlFenced { request_id, epoch } => {
                name(request_id)?;
                epoch_valid(*epoch)?;
            }
            Self::Screen { channel, screen } => {
                name(channel)?;
                screen.validate().map_err(|_| invalid())?;
            }
            Self::Frozen {
                request_id,
                workspace,
            } => {
                name(request_id)?;
                if let Some(workspace) = workspace {
                    workspace.validate().map_err(|_| invalid())?;
                }
            }
            Self::Stopped => (),
        }
        Ok(())
    }
}

pub trait GuestMessage: Serialize + for<'a> Deserialize<'a> {
    fn validate_message(&self) -> std::io::Result<()>;
}
impl GuestMessage for GuestRequest {
    fn validate_message(&self) -> std::io::Result<()> {
        self.validate()
    }
}
impl GuestMessage for GuestEvent {
    fn validate_message(&self) -> std::io::Result<()> {
        self.validate()
    }
}

pub fn read_frame<T: GuestMessage>(reader: &mut impl Read) -> std::io::Result<T> {
    let mut length = [0; 4];
    reader.read_exact(&mut length)?;
    let length = u32::from_be_bytes(length) as usize;
    if length == 0 || length > MAX_FRAME_BYTES {
        return Err(invalid());
    }
    let mut bytes = vec![0; length];
    reader.read_exact(&mut bytes)?;
    let message: T = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    message.validate_message()?;
    Ok(message)
}

pub fn write_frame<T: GuestMessage>(writer: &mut impl Write, value: &T) -> std::io::Result<()> {
    value.validate_message()?;
    let bytes = serde_json::to_vec(value).map_err(|_| invalid())?;
    if bytes.len() > MAX_FRAME_BYTES {
        return Err(invalid());
    }
    writer.write_all(&(bytes.len() as u32).to_be_bytes())?;
    writer.write_all(&bytes)?;
    writer.flush()
}

fn name(value: &str) -> std::io::Result<()> {
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .all(|v| v.is_ascii_alphanumeric() || b"._:/-".contains(&v))
        || value.contains("..")
        || value.contains("//")
    {
        return Err(invalid());
    }
    Ok(())
}
fn epoch_valid(epoch: u64) -> std::io::Result<()> {
    if epoch == 0 {
        return Err(invalid());
    }
    Ok(())
}
fn challenge_valid(value: &str) -> std::io::Result<()> {
    if value.len() != 64 || !value.bytes().all(|v| v.is_ascii_hexdigit()) {
        return Err(invalid());
    }
    Ok(())
}
fn invalid() -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid_guest_message")
}

impl std::fmt::Debug for GuestRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("GuestRequest(<redacted>)")
    }
}
impl std::fmt::Debug for GuestEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("GuestEvent(<redacted>)")
    }
}
