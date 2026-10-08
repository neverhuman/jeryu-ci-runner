//! Non-secret references to encrypted workspace disks. Never a RAM snapshot.
use super::{SessionContext, WorkspaceReady, message_io};
use crate::wire::validation::{
    ValidateWire, WireError, WireErrorCode, validate_digest, validate_timestamp,
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CheckpointReference {
    pub checkpoint_id: String,
    pub manifest_digest: String,
}
impl ValidateWire for CheckpointReference {
    fn validate_wire(&self) -> Result<(), WireError> {
        if self.checkpoint_id.len() != 32
            || !self
                .checkpoint_id
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(WireError::new(WireErrorCode::InvalidField, "checkpoint_id"));
        }
        validate_digest("manifest_digest", &self.manifest_digest)
    }
}
message_io!(CheckpointReference);

/// Missing format is the historical dense image; its JSON omits the default
/// so previously retained manifest/reference bytes remain unchanged.
#[derive(
    Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum CheckpointFormat {
    #[default]
    LegacyDenseV1,
    SparseV2,
}
impl CheckpointFormat {
    pub fn is_legacy(&self) -> bool {
        *self == Self::LegacyDenseV1
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CheckpointManifest {
    #[serde(default, skip_serializing_if = "CheckpointFormat::is_legacy")]
    pub format: CheckpointFormat,
    pub checkpoint_id: String,
    pub context: SessionContext,
    pub workspace: Option<WorkspaceReady>,
    pub plaintext_bytes: u64,
    pub plaintext_digest: String,
    pub ciphertext_digest: String,
    pub filesystem_flushed: bool,
    pub created_at_unix_millis: u64,
    pub expires_at_unix_millis: u64,
}
impl ValidateWire for CheckpointManifest {
    fn validate_wire(&self) -> Result<(), WireError> {
        CheckpointReference {
            checkpoint_id: self.checkpoint_id.clone(),
            manifest_digest: self.plaintext_digest.clone(),
        }
        .validate()?;
        self.context.validate_wire()?;
        if let Some(workspace) = &self.workspace {
            workspace.validate_wire()?;
        }
        validate_digest("ciphertext_digest", &self.ciphertext_digest)?;
        validate_timestamp("created_at_unix_millis", self.created_at_unix_millis)?;
        validate_timestamp("expires_at_unix_millis", self.expires_at_unix_millis)?;
        if self.plaintext_bytes == 0
            || self.plaintext_bytes > 1024 * 1024 * 1024 * 1024
            || self
                .expires_at_unix_millis
                .checked_sub(self.created_at_unix_millis)
                != Some(7 * 24 * 60 * 60 * 1000)
        {
            return Err(WireError::new(
                WireErrorCode::InvalidField,
                "checkpoint_retention",
            ));
        }
        Ok(())
    }
}
message_io!(CheckpointManifest);
