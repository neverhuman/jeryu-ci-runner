//! K2 streaming, K4 registry upload, and K3 relay metadata. No runtime here.
use super::{
    CheckpointReference, ControlAck, Provider, SessionContext, TerminalFrame, WorkspaceReady,
    header, message_io, positive,
};
use crate::wire::validation::{
    ValidateWire, WireError, WireErrorCode, validate_digest, validate_id, validate_label,
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum RuntimePhase {
    Running,
    RebaseRequired,
    Stopping,
    Checkpointing,
    Stopped,
    Failed,
}
#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ChannelSnapshot {
    pub channel_id: String,
    pub started: bool,
    pub exited: bool,
    pub exit_code: Option<i32>,
    pub cursor: u64,
    pub earliest_cursor: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SessionSnapshot {
    pub context: SessionContext,
    pub workspace: Option<WorkspaceReady>,
    pub checkpoint: Option<CheckpointReference>,
    pub phase: RuntimePhase,
    pub reason: Option<String>,
    #[schemars(length(max = 2))]
    pub channels: Vec<ChannelSnapshot>,
}
#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ControllerLease {
    pub context: SessionContext,
    pub actor: String,
    pub controller_id: String,
    pub terminal_channels: Vec<String>,
    pub epoch: u64,
    pub expires_in_seconds: u32,
    pub next_sequence: u64,
}
/// Only real terminals holding the writer lease suppress headless query replies.
pub fn validate_terminal_channels(channels: &[String]) -> Result<(), WireError> {
    if channels.len() > 2
        || channels.iter().any(|c| c != "agent" && c != "shell")
        || channels.windows(2).any(|c| c[0] >= c[1])
    {
        return Err(WireError::new(
            WireErrorCode::InvalidCollection,
            "terminal_channels",
        ));
    }
    Ok(())
}

pub fn validate_control_identity(actor: &str, client_id: &str) -> Result<(), WireError> {
    validate_id("actor", actor)?;
    validate_id("controller_id", client_id)
}
#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SessionSubscribe {
    #[schemars(schema_with = "super::schema::version")]
    pub protocol_version: String,
    pub message_type: String,
    pub request_id: String,
    pub actor: String,
    pub session_id: String,
    pub generation: u64,
    pub channel_id: String,
    /// Last consumed terminal sequence, exclusive. Zero starts retained replay.
    pub after_sequence: u64,
}
impl ValidateWire for SessionSubscribe {
    fn validate_wire(&self) -> Result<(), WireError> {
        header(
            &self.protocol_version,
            &self.message_type,
            "session-subscribe",
        )?;
        for (name, value) in [
            ("request_id", &self.request_id),
            ("actor", &self.actor),
            ("session_id", &self.session_id),
        ] {
            validate_id(name, value)?;
        }
        positive("generation", self.generation)?;
        validate_label("channel_id", &self.channel_id)
    }
}
message_io!(SessionSubscribe);

#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(tag = "event", rename_all = "kebab-case", deny_unknown_fields)]
pub enum SessionStreamEvent {
    Terminal { frame: TerminalFrame },
    Control { acknowledgement: ControlAck },
    Snapshot { snapshot: SessionSnapshot },
    End { reason: String },
    Heartbeat,
}
#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SessionStreamFrame {
    #[schemars(schema_with = "super::schema::version")]
    pub protocol_version: String,
    pub message_type: String,
    pub request_id: String,
    pub session_id: String,
    pub generation: u64,
    pub channel_id: String,
    pub payload: SessionStreamEvent,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum BundleRole {
    SourceBundle,
}
#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BundleUpload {
    #[schemars(schema_with = "super::schema::version")]
    pub protocol_version: String,
    pub message_type: String,
    pub request_id: String,
    pub role: BundleRole,
    #[schemars(schema_with = "super::schema::digest")]
    pub digest: String,
    /// Registry bytes include deterministic zero padding to a block boundary.
    #[schemars(range(min = 512, max = 1073741824))]
    pub stored_bytes: u64,
    pub bundle_bytes: u64,
}
impl ValidateWire for BundleUpload {
    fn validate_wire(&self) -> Result<(), WireError> {
        header(&self.protocol_version, &self.message_type, "bundle-upload")?;
        validate_id("request_id", &self.request_id)?;
        validate_digest("digest", &self.digest)?;
        if self.bundle_bytes == 0
            || self.bundle_bytes > 1024 * 1024 * 1024
            || self.stored_bytes > 1024 * 1024 * 1024
            || self.stored_bytes != self.bundle_bytes.div_ceil(512) * 512
        {
            return Err(WireError::new(WireErrorCode::InvalidField, "bundle_length"));
        }
        Ok(())
    }
}
message_io!(BundleUpload);

/// Successful K4 registration binds the uploaded bytes, not repository trust.
#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BundleRegistered {
    #[schemars(schema_with = "super::schema::version")]
    pub protocol_version: String,
    pub message_type: String,
    pub request_id: String,
    pub role: BundleRole,
    pub artifact: super::ArtifactIdentity,
    pub bundle_bytes: u64,
    pub stored_bytes: u64,
}
impl ValidateWire for BundleRegistered {
    fn validate_wire(&self) -> Result<(), WireError> {
        header(
            &self.protocol_version,
            &self.message_type,
            "bundle-registered",
        )?;
        self.artifact.validate_wire()?;
        BundleUpload {
            protocol_version: self.protocol_version.clone(),
            message_type: "bundle-upload".into(),
            request_id: self.request_id.clone(),
            role: self.role,
            digest: self.artifact.digest.clone(),
            bundle_bytes: self.bundle_bytes,
            stored_bytes: self.stored_bytes,
        }
        .validate()
    }
}
message_io!(BundleRegistered);
impl BundleRegistered {
    pub fn validate_for(&self, upload: &BundleUpload) -> Result<(), WireError> {
        self.validate()?;
        upload.validate()?;
        if self.request_id != upload.request_id
            || self.role != upload.role
            || self.artifact.digest != upload.digest
            || self.bundle_bytes != upload.bundle_bytes
            || self.stored_bytes != upload.stored_bytes
        {
            return Err(WireError::new(
                WireErrorCode::ContextMismatch,
                "bundle_registration",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "UPPERCASE")]
pub enum RelayMethod {
    Get,
    Post,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum RelayHeaderName {
    Accept,
    ContentType,
}
#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RelayHeader {
    pub name: RelayHeaderName,
    pub value: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GuestRelayRequest {
    #[schemars(schema_with = "super::schema::version")]
    pub protocol_version: String,
    pub message_type: String,
    pub request_id: String,
    pub session_id: String,
    pub generation: u64,
    pub run_id: String,
    pub lease_id: String,
    pub lease_epoch: u64,
    pub provider: Provider,
    pub method: RelayMethod,
    /// Relative provider API path, no authority, fragment, or credentials.
    pub path: String,
    #[schemars(length(max = 2))]
    pub headers: Vec<RelayHeader>,
}
impl ValidateWire for GuestRelayRequest {
    fn validate_wire(&self) -> Result<(), WireError> {
        header(
            &self.protocol_version,
            &self.message_type,
            "guest-relay-request",
        )?;
        for (name, value) in [
            ("request_id", &self.request_id),
            ("session_id", &self.session_id),
            ("run_id", &self.run_id),
            ("lease_id", &self.lease_id),
        ] {
            validate_id(name, value)?;
        }
        positive("generation", self.generation)?;
        positive("lease_epoch", self.lease_epoch)?;
        if self.path.len() > 2048
            || !self.path.starts_with('/')
            || self.path.contains("//")
            || !self.path.is_ascii()
            || self.path.bytes().any(|b| b <= 32 || b == 127)
            || self.path.contains(['#', '\\', '@', '?', '%'])
            || self.path.split('/').any(|p| p == "." || p == "..")
            || self.headers.len() > 2
        {
            return Err(WireError::new(WireErrorCode::InvalidField, "relay_path"));
        }
        for (index, header) in self.headers.iter().enumerate() {
            if header.value.len() > 256
                || !header.value.is_ascii()
                || header.value.bytes().any(|b| b < 32 || b == 127)
                || self.headers[..index].iter().any(|h| h.name == header.name)
            {
                return Err(WireError::new(WireErrorCode::InvalidField, "relay_header"));
            }
        }
        Ok(())
    }
}
message_io!(GuestRelayRequest);
