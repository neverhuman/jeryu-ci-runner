//! New work must synchronize against an immutable, trusted main resolution.
use super::{ArtifactIdentity, SessionContext, message_io};
use crate::wire::validation::{ValidateWire, WireError, WireErrorCode, validate_head_sha};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
pub enum WorkspaceSource {
    /// Model-free empty-disk fixture only. Never a repository readiness receipt.
    EmptyFixture,
    GitBundle {
        bundle: ArtifactIdentity,
        /// Exact bundle length, excluding block-device alignment padding.
        #[schemars(range(min = 1, max = 1073741824))]
        bundle_bytes: u64,
        main_revision: String,
        /// Base of retained work. The source head is bound in SessionContext.
        base_revision: String,
    },
}
impl WorkspaceSource {
    pub fn validate_for(&self, context: &SessionContext, profile: &str) -> Result<(), WireError> {
        match self {
            Self::EmptyFixture if profile != "fixture" => Err(WireError::new(
                WireErrorCode::ContextMismatch,
                "workspace_source",
            )),
            Self::EmptyFixture => Ok(()),
            Self::GitBundle {
                bundle,
                bundle_bytes,
                main_revision,
                base_revision,
            } => {
                bundle.validate_wire()?;
                validate_head_sha(main_revision)?;
                validate_head_sha(base_revision)?;
                validate_head_sha(&context.source_revision)?;
                if *bundle_bytes == 0 || *bundle_bytes > 1024 * 1024 * 1024 {
                    return Err(WireError::new(WireErrorCode::InvalidField, "bundle_bytes"));
                }
                Ok(())
            }
        }
    }
}

/// Produced by guest Git, after checking the bundle refs and successful rebase.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WorkspaceReady {
    pub source_revision: String,
    pub main_revision: String,
    pub head_revision: String,
    pub sync_state: WorkspaceSyncState,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum WorkspaceSyncState {
    Ready,
    RebaseRequired,
}
impl ValidateWire for WorkspaceReady {
    fn validate_wire(&self) -> Result<(), WireError> {
        for revision in [
            &self.source_revision,
            &self.main_revision,
            &self.head_revision,
        ] {
            validate_head_sha(revision)?;
        }
        Ok(())
    }
}
message_io!(WorkspaceReady);
