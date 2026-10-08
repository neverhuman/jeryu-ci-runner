//! Guest/node mirror of lane A's k3-relay-v1. No capability or session authority
//! is representable on this socket. Gateway capabilities remain host-only.
mod validation;
use crate::wire::v2::{Provider, RelayHeader, RelayMethod};
use serde::{Deserialize, Serialize};
use std::fmt;
pub use validation::body_bytes;
pub(crate) use validation::metadata;

pub const MAX_FRAME_BYTES: usize = 256 * 1024;
pub const MAX_BODY_BYTES: usize = 32768;
pub const WINDOW_BYTES: usize = 1024 * 1024;
pub const MAX_IN_FLIGHT: usize = 4;
pub const IDLE_SECONDS: u64 = 60;

#[derive(Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(tag = "type", rename_all = "kebab-case", deny_unknown_fields)]
pub enum GuestRelayFrame {
    Open {
        #[schemars(schema_with = "validation::id_schema")]
        request_id: String,
        provider: Provider,
        method: RelayMethod,
        #[schemars(length(min = 2, max = 2048))]
        path: String,
        #[schemars(length(max = 2))]
        headers: Vec<RelayHeader>,
        /// Deserialize to reject helper credentials with a fixed error only.
        /// RAM-token modes are disabled; this field is never forwarded.
        #[serde(
            default,
            deserialize_with = "validation::authorization",
            skip_serializing_if = "Option::is_none"
        )]
        #[schemars(with = "String", length(min = 1, max = 4096))]
        authorization: Option<String>,
    },
    RequestBody {
        #[schemars(schema_with = "validation::id_schema")]
        request_id: String,
        #[schemars(range(min = 1))]
        seq: u64,
        #[schemars(schema_with = "validation::body_schema")]
        bytes_b64: String,
    },
    RequestEnd {
        #[schemars(schema_with = "validation::id_schema")]
        request_id: String,
        seq_end: u64,
    },
    Ack {
        #[schemars(schema_with = "validation::id_schema")]
        request_id: String,
        #[schemars(range(min = 1))]
        through_seq: u64,
    },
    Cancel {
        #[schemars(schema_with = "validation::id_schema")]
        request_id: String,
    },
}
#[derive(Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(tag = "type", rename_all = "kebab-case", deny_unknown_fields)]
pub enum NodeRelayFrame {
    Head {
        #[schemars(schema_with = "validation::id_schema")]
        request_id: String,
        #[schemars(range(min = 100, max = 599))]
        status: u16,
        #[schemars(length(max = 1))]
        headers: Vec<RelayHeader>,
    },
    ResponseBody {
        #[schemars(schema_with = "validation::id_schema")]
        request_id: String,
        #[schemars(range(min = 1))]
        seq: u64,
        #[schemars(schema_with = "validation::body_schema")]
        bytes_b64: String,
    },
    ResponseEnd {
        #[schemars(schema_with = "validation::id_schema")]
        request_id: String,
        seq_end: u64,
    },
    Ack {
        #[schemars(schema_with = "validation::id_schema")]
        request_id: String,
        #[schemars(range(min = 1))]
        through_seq: u64,
    },
    Error {
        #[schemars(schema_with = "validation::id_schema")]
        request_id: String,
        error: RelayErrorCode,
    },
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum RelayErrorCode {
    ProviderNotConnected,
    ConnectionGenerationStale,
    ConnectionOwnerMismatch,
    ProviderModeDisabled,
    ProviderModeUnqualified,
    HelperRequired,
    RamTokenNotPermitted,
    CapabilityUnverified,
    CapabilityExpired,
    CapabilityAudienceMismatch,
    UpstreamHostDenied,
    RefreshPersistFailed,
    ProviderUnknown,
    LeaseBindingMismatch,
    ConnectionBusy,
    GuestAuthorizationRejected,
    RelayIdleTimeout,
    RelayStreamInvalid,
}
impl fmt::Display for RelayErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let value = serde_json::to_value(self).map_err(|_| fmt::Error)?;
        f.write_str(value.as_str().ok_or(fmt::Error)?)
    }
}
impl std::error::Error for RelayErrorCode {}

impl GuestRelayFrame {
    pub fn request_id(&self) -> &str {
        match self {
            Self::Open { request_id, .. }
            | Self::RequestBody { request_id, .. }
            | Self::RequestEnd { request_id, .. }
            | Self::Ack { request_id, .. }
            | Self::Cancel { request_id } => request_id,
        }
    }
}
impl NodeRelayFrame {
    pub fn request_id(&self) -> &str {
        match self {
            Self::Head { request_id, .. }
            | Self::ResponseBody { request_id, .. }
            | Self::ResponseEnd { request_id, .. }
            | Self::Ack { request_id, .. }
            | Self::Error { request_id, .. } => request_id,
        }
    }
}
// Even malicious header values, request ids and rejected authorization must
// never become credential/prompt output through a derived debug formatter.
impl fmt::Debug for GuestRelayFrame {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("GuestRelayFrame { content: redacted }")
    }
}
impl fmt::Debug for NodeRelayFrame {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("NodeRelayFrame { content: redacted }")
    }
}
/// Schema envelope only. Transport consumers must select a concrete direction.
#[derive(Serialize, Deserialize, schemars::JsonSchema)]
#[serde(untagged)]
pub enum RelayFrame {
    Guest(GuestRelayFrame),
    Node(NodeRelayFrame),
}
pub fn schema() -> schemars::Schema {
    schemars::schema_for!(RelayFrame)
}
