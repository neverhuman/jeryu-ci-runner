use super::{
    CheckpointReference, RuntimeManifest, SessionResources, WorkspaceSource, header, message_io,
    positive,
};
use crate::wire::validation::{
    CanonicalSha256, ValidateWire, WireError, WireErrorCode, validate_digest, validate_head_sha,
    validate_id, validate_label, validate_repository, validate_timestamp,
};
use serde::{Deserialize, Serialize};

/// V2 managed leases cannot encode CI or request another runner backend.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum ManagedPurpose {
    ManagedAgent,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SessionContext {
    #[schemars(schema_with = "super::schema::id")]
    pub session_id: String,
    #[schemars(range(min = 1))]
    pub generation: u64,
    #[schemars(schema_with = "super::schema::id")]
    pub run_id: String,
    #[schemars(schema_with = "super::schema::owner")]
    pub owner_id: String,
    pub repository: String,
    pub source_revision: String,
    #[schemars(schema_with = "super::schema::id")]
    pub runner_id: String,
    #[schemars(range(min = 1))]
    pub runner_epoch: u64,
    #[schemars(schema_with = "super::schema::id")]
    pub lease_id: String,
    #[schemars(range(min = 1))]
    pub lease_epoch: u64,
    #[schemars(schema_with = "super::schema::digest")]
    pub job_digest: String,
    #[schemars(schema_with = "super::schema::digest")]
    pub environment_digest: String,
    #[schemars(schema_with = "super::schema::digest")]
    pub runtime_digest: String,
    #[schemars(schema_with = "super::schema::digest")]
    pub policy_revision: String,
}

impl ValidateWire for SessionContext {
    fn validate_wire(&self) -> Result<(), WireError> {
        for (name, id) in [
            ("session_id", &self.session_id),
            ("run_id", &self.run_id),
            ("owner_id", &self.owner_id),
            ("runner_id", &self.runner_id),
            ("lease_id", &self.lease_id),
        ] {
            validate_id(name, id)?;
        }
        positive("generation", self.generation)?;
        if !self.owner_id.starts_with("user/") && !self.owner_id.starts_with("service/") {
            return Err(WireError::new(WireErrorCode::InvalidField, "owner_id"));
        }
        positive("runner_epoch", self.runner_epoch)?;
        positive("lease_epoch", self.lease_epoch)?;
        validate_repository(&self.repository)?;
        validate_head_sha(&self.source_revision)?;
        for (name, digest) in [
            ("job_digest", &self.job_digest),
            ("environment_digest", &self.environment_digest),
            ("runtime_digest", &self.runtime_digest),
            ("policy_revision", &self.policy_revision),
        ] {
            validate_digest(name, digest)?;
        }
        Ok(())
    }
}
message_io!(SessionContext);

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SessionLease {
    #[schemars(schema_with = "super::schema::version")]
    pub protocol_version: String,
    #[schemars(schema_with = "super::schema::lease_type")]
    pub message_type: String,
    pub purpose: ManagedPurpose,
    pub context: SessionContext,
    #[schemars(schema_with = "super::schema::label")]
    pub profile_id: String,
    pub workspace: WorkspaceSource,
    pub checkpoint: Option<CheckpointReference>,
    #[schemars(length(max = 3))]
    pub connection_bindings: Vec<super::ConnectionBinding>,
    pub runtime: RuntimeManifest,
    pub resources: SessionResources,
    pub issued_at_unix_millis: u64,
    pub expires_at_unix_millis: u64,
    #[schemars(schema_with = "super::schema::signature")]
    pub signature: String,
}

impl SessionLease {
    /// Bind immutable work inputs independently of assignment/lease epochs.
    pub fn job_digest(&self) -> Result<String, WireError> {
        let inputs = serde_json::to_string(&(
            self.purpose,
            &self.context.session_id,
            self.context.generation,
            &self.context.owner_id,
            &self.context.repository,
            &self.context.source_revision,
            &self.context.environment_digest,
            &self.context.runtime_digest,
            &self.context.policy_revision,
            &self.profile_id,
            &self.workspace,
            &self.checkpoint,
            &self.connection_bindings,
            &self.resources,
        ))
        .map_err(|_| WireError::new(WireErrorCode::InvalidJson, "job_inputs"))?;
        let mut digest = CanonicalSha256::new("jeryu.runner.managed-job.v2.1");
        digest.field("inputs", &inputs);
        Ok(digest.finish())
    }
    /// Shape/time/assignment validation. The node must also verify the Ed25519
    /// signature against its enrolled key before reserving or booting resources.
    pub fn validate_for_runner(
        &self,
        runner_id: &str,
        runner_epoch: u64,
        now: u64,
    ) -> Result<(), WireError> {
        self.validate()?;
        if self.context.runner_id != runner_id
            || self.context.runner_epoch != runner_epoch
            || now < self.issued_at_unix_millis
            || now >= self.expires_at_unix_millis
        {
            return Err(WireError::new(WireErrorCode::ContextMismatch, "lease"));
        }
        Ok(())
    }
}

impl ValidateWire for SessionLease {
    fn validate_wire(&self) -> Result<(), WireError> {
        header(&self.protocol_version, &self.message_type, "session-lease")?;
        self.context.validate_wire()?;
        validate_label("profile_id", &self.profile_id)?;
        super::connection::validate_bindings(&self.connection_bindings)?;
        if (self.runtime.image_class == super::RuntimeImageClass::Test
            || self.profile_id == "shell")
            && !self.connection_bindings.is_empty()
        {
            return Err(WireError::new(
                WireErrorCode::ContextMismatch,
                "fixture_provider_access",
            ));
        }
        if self.signature.len() != 128
            || !self
                .signature
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(WireError::new(
                WireErrorCode::InvalidField,
                "lease_signature",
            ));
        }
        let provider = match self.profile_id.as_str() {
            "claude" => Some(super::Provider::Claude),
            "codex" => Some(super::Provider::Codex),
            "grok" => Some(super::Provider::Grok),
            _ => None,
        };
        if provider.is_some_and(|provider| {
            !self
                .connection_bindings
                .iter()
                .any(|b| b.provider == provider)
        }) {
            return Err(WireError::new(
                WireErrorCode::ContextMismatch,
                "provider_connection",
            ));
        }
        self.workspace
            .validate_for(&self.context, &self.profile_id)?;
        if let Some(checkpoint) = &self.checkpoint {
            checkpoint.validate_wire()?;
        }
        self.runtime.validate_wire()?;
        if !self.runtime.permits_profile(&self.profile_id) {
            return Err(WireError::new(
                WireErrorCode::ContextMismatch,
                "runtime_profile",
            ));
        }
        self.resources.validate_wire()?;
        validate_timestamp("issued_at_unix_millis", self.issued_at_unix_millis)?;
        validate_timestamp("expires_at_unix_millis", self.expires_at_unix_millis)?;
        let duration = self
            .expires_at_unix_millis
            .checked_sub(self.issued_at_unix_millis);
        if !duration.is_some_and(|v| v > 0 && v <= u64::from(self.resources.runtime_seconds) * 1000)
            || self.context.environment_digest != self.runtime.environment_digest
            || self.context.policy_revision != self.runtime.policy_revision
            || self.context.runtime_digest != runtime_digest(&self.runtime)?
            || self.context.job_digest != self.job_digest()?
        {
            return Err(WireError::new(
                WireErrorCode::ContextMismatch,
                "runtime_binding",
            ));
        }
        Ok(())
    }
}
message_io!(SessionLease);

/// A domain-separated digest binds all runtime inputs, including architecture and ABI.
pub fn runtime_digest(runtime: &RuntimeManifest) -> Result<String, WireError> {
    let bytes = runtime.to_json()?;
    let mut digest = CanonicalSha256::new("jeryu.runner.runtime.v2");
    digest.field(
        "manifest",
        std::str::from_utf8(&bytes)
            .map_err(|_| WireError::new(WireErrorCode::InvalidJson, "runtime"))?,
    );
    Ok(digest.finish())
}
