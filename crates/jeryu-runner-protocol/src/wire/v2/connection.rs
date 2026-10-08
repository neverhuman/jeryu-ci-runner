//! Public connection references, never credential material.
use crate::wire::validation::{ValidateWire, WireError, WireErrorCode, validate_id};
use serde::{Deserialize, Serialize};

#[derive(
    Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
    Claude,
    Codex,
    Grok,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionMode {
    GatewayHelper,
    QualifiedRamToken,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ConnectionBinding {
    pub provider: Provider,
    #[schemars(schema_with = "super::schema::id")]
    pub connection_id: String,
    #[schemars(range(min = 1))]
    pub connection_generation: u64,
    pub mode: ConnectionMode,
}
impl ValidateWire for ConnectionBinding {
    fn validate_wire(&self) -> Result<(), WireError> {
        validate_id("connection_id", &self.connection_id)?;
        super::positive("connection_generation", self.connection_generation)
    }
}
pub(super) fn validate_bindings(bindings: &[ConnectionBinding]) -> Result<(), WireError> {
    if bindings.len() > 3 {
        return Err(WireError::new(
            WireErrorCode::InvalidCollection,
            "connection_bindings",
        ));
    }
    let mut previous = None;
    for binding in bindings {
        binding.validate_wire()?;
        // One account/mode per provider; strict order makes equivalent inputs
        // have one job identity and prevents implicit account selection.
        if previous.is_some_and(|provider| provider >= binding.provider) {
            return Err(WireError::new(
                WireErrorCode::InvalidCollection,
                "connection_bindings",
            ));
        }
        previous = Some(binding.provider);
    }
    Ok(())
}
