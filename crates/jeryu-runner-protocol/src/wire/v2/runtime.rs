use super::{FIRECRACKER_VERSION, GUEST_PROTOCOL_VERSION, message_io};
use crate::wire::validation::{
    ValidateWire, WireError, WireErrorCode, validate_digest, validate_label, validate_text,
};
use serde::{Deserialize, Serialize};

/// Content identity resolved by a trusted artifact registry, never by guest paths.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ArtifactIdentity {
    #[schemars(schema_with = "super::schema::label")]
    pub artifact_id: String,
    #[schemars(schema_with = "super::schema::digest")]
    pub digest: String,
}

impl ValidateWire for ArtifactIdentity {
    fn validate_wire(&self) -> Result<(), WireError> {
        validate_label("artifact_id", &self.artifact_id)?;
        validate_digest("artifact_digest", &self.digest)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum RuntimeArchitecture {
    X86_64,
    Aarch64,
}

/// Release identity. Signature verification and live qualification must precede
/// registry admission; a well-formed manifest alone is not evidence of either.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RuntimeManifest {
    #[schemars(schema_with = "super::schema::firecracker_version")]
    pub firecracker_version: String,
    #[schemars(schema_with = "super::schema::guest_version")]
    pub guest_protocol_version: String,
    pub architecture: RuntimeArchitecture,
    pub kernel_version: String,
    pub firecracker: ArtifactIdentity,
    pub jailer: ArtifactIdentity,
    pub kernel: ArtifactIdentity,
    pub rootfs: ArtifactIdentity,
    pub guestd: ArtifactIdentity,
    pub agent: ArtifactIdentity,
    pub toolchain: ArtifactIdentity,
    #[schemars(schema_with = "super::schema::digest")]
    pub environment_digest: String,
    #[schemars(schema_with = "super::schema::digest")]
    pub recipe_digest: String,
    #[schemars(schema_with = "super::schema::digest")]
    pub policy_revision: String,
    #[schemars(schema_with = "super::schema::label")]
    pub snapshot_compatibility: String,
}

impl ValidateWire for RuntimeManifest {
    fn validate_wire(&self) -> Result<(), WireError> {
        if self.firecracker_version != FIRECRACKER_VERSION
            || self.guest_protocol_version != GUEST_PROTOCOL_VERSION
        {
            return Err(WireError::new(
                WireErrorCode::InvalidProtocol,
                "runtime_version",
            ));
        }
        validate_text("kernel_version", &self.kernel_version, 64)?;
        if self.kernel_version.is_empty() {
            return Err(WireError::new(
                WireErrorCode::InvalidField,
                "kernel_version",
            ));
        }
        for artifact in [
            &self.firecracker,
            &self.jailer,
            &self.kernel,
            &self.rootfs,
            &self.guestd,
            &self.agent,
            &self.toolchain,
        ] {
            artifact.validate_wire()?;
        }
        for (name, digest) in [
            ("environment_digest", &self.environment_digest),
            ("recipe_digest", &self.recipe_digest),
            ("policy_revision", &self.policy_revision),
        ] {
            validate_digest(name, digest)?;
        }
        validate_label("snapshot_compatibility", &self.snapshot_compatibility)
    }
}
message_io!(RuntimeManifest);

/// Admission bounds. Defaults are the initial session shape, not a capacity grant.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SessionResources {
    #[schemars(range(min = 1, max = 32))]
    pub vcpus: u8,
    #[schemars(range(min = 128, max = 65536))]
    pub memory_mib: u32,
    #[schemars(range(min = 1, max = 512))]
    pub workspace_gib: u32,
    #[schemars(range(min = 16, max = 4096))]
    pub pids_max: u32,
    #[schemars(range(min = 1024, max = 1048576))]
    pub output_bytes_per_second: u32,
    #[schemars(range(min = 1, max = 7200))]
    pub runtime_seconds: u32,
    #[schemars(range(min = 1, max = 900))]
    pub idle_seconds: u32,
    pub git_limits: GitLimits,
}

impl Default for SessionResources {
    fn default() -> Self {
        Self {
            vcpus: 2,
            memory_mib: 4096,
            workspace_gib: 16,
            pids_max: 1024,
            output_bytes_per_second: 1024 * 1024,
            runtime_seconds: 7200,
            idle_seconds: 900,
            git_limits: GitLimits::default(),
        }
    }
}

impl ValidateWire for SessionResources {
    fn validate_wire(&self) -> Result<(), WireError> {
        if !(1..=32).contains(&self.vcpus)
            || !(128..=65536).contains(&self.memory_mib)
            || !(1..=512).contains(&self.workspace_gib)
            || !(16..=4096).contains(&self.pids_max)
            || !(1024..=1024 * 1024).contains(&self.output_bytes_per_second)
            || !(1..=7200).contains(&self.runtime_seconds)
            || !(1..=900).contains(&self.idle_seconds)
            || self.idle_seconds > self.runtime_seconds
        {
            return Err(WireError::new(WireErrorCode::InvalidField, "resources"));
        }
        self.git_limits.validate()
    }
}
message_io!(SessionResources);

/// Trusted preparation bounds, signed as part of resources and the job digest.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GitLimits {
    #[schemars(range(min = 1, max = 300))]
    pub timeout_seconds: u32,
    #[schemars(range(min = 4096, max = 8388608))]
    pub stdout_bytes: u32,
    #[schemars(range(min = 256, max = 65536))]
    pub stderr_bytes: u32,
}
impl Default for GitLimits {
    fn default() -> Self {
        Self {
            timeout_seconds: 30,
            stdout_bytes: 65536,
            stderr_bytes: 4096,
        }
    }
}
impl ValidateWire for GitLimits {
    fn validate_wire(&self) -> Result<(), WireError> {
        if !(1..=300).contains(&self.timeout_seconds)
            || !(4096..=8 * 1024 * 1024).contains(&self.stdout_bytes)
            || !(256..=65536).contains(&self.stderr_bytes)
        {
            return Err(WireError::new(WireErrorCode::InvalidField, "git_limits"));
        }
        Ok(())
    }
}
message_io!(GitLimits);
