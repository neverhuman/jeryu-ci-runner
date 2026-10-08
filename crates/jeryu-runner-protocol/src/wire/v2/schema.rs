//! The Rust types and their schema attributes own this mirror. Runtime validation
//! additionally enforces bindings, time order, and terminal gap semantics.
use super::{
    BundleUpload, CheckpointManifest, ControlAck, ControlRequest, GuestRelayRequest, SessionLease,
    SessionRpcRequest, SessionRpcResponse, SessionStreamFrame, SessionSubscribe, TerminalFrame,
};
use schemars::{JsonSchema, Schema};
use serde::{Deserialize, Serialize};

#[derive(JsonSchema, Serialize, Deserialize)]
#[serde(untagged)]
enum ManagedMessage {
    Lease(Box<SessionLease>),
    Control(Box<ControlRequest>),
    Ack(Box<ControlAck>),
    Terminal(Box<TerminalFrame>),
    Rpc(Box<SessionRpcRequest>),
    Response(Box<SessionRpcResponse>),
    Subscribe(Box<SessionSubscribe>),
    Stream(Box<SessionStreamFrame>),
    Upload(Box<BundleUpload>),
    Relay(Box<GuestRelayRequest>),
    Checkpoint(Box<CheckpointManifest>),
}

pub fn schema() -> Schema {
    schemars::schema_for!(ManagedMessage)
}

pub(super) fn digest(_: &mut schemars::SchemaGenerator) -> Schema {
    schemars::json_schema!({"type":"string","pattern":"^sha256:[0-9a-f]{64}$"})
}
pub(super) fn signature(_: &mut schemars::SchemaGenerator) -> Schema {
    schemars::json_schema!({"type":"string","pattern":"^[0-9a-f]{128}$"})
}
pub(super) fn id(_: &mut schemars::SchemaGenerator) -> Schema {
    schemars::json_schema!({"type":"string","minLength":1,"maxLength":128,
        "pattern":"^[a-zA-Z0-9][a-zA-Z0-9._:/-]*[a-zA-Z0-9]$|^[a-zA-Z0-9]$"})
}
pub(super) fn label(_: &mut schemars::SchemaGenerator) -> Schema {
    schemars::json_schema!({"type":"string","minLength":1,"maxLength":64,
        "pattern":"^[a-z0-9][a-z0-9._-]*[a-z0-9]$|^[a-z0-9]$"})
}
pub(super) fn owner(_: &mut schemars::SchemaGenerator) -> Schema {
    schemars::json_schema!({"type":"string","minLength":6,"maxLength":128,
        "pattern":"^(user|service)/[a-zA-Z0-9]([a-zA-Z0-9._:/-]*[a-zA-Z0-9])?$"})
}
pub(super) fn version(_: &mut schemars::SchemaGenerator) -> Schema {
    schemars::json_schema!({"type":"string","const":super::PROTOCOL_VERSION})
}
pub(super) fn lease_type(_: &mut schemars::SchemaGenerator) -> Schema {
    schemars::json_schema!({"type":"string","const":"session-lease"})
}
pub(super) fn control_type(_: &mut schemars::SchemaGenerator) -> Schema {
    schemars::json_schema!({"type":"string","const":"session-control"})
}
pub(super) fn ack_type(_: &mut schemars::SchemaGenerator) -> Schema {
    schemars::json_schema!({"type":"string","const":"session-control-ack"})
}
pub(super) fn terminal_type(_: &mut schemars::SchemaGenerator) -> Schema {
    schemars::json_schema!({"type":"string","const":"session-terminal"})
}
pub(super) fn rpc_type(_: &mut schemars::SchemaGenerator) -> Schema {
    schemars::json_schema!({"type":"string","const":"session-rpc"})
}
pub(super) fn rpc_response_type(_: &mut schemars::SchemaGenerator) -> Schema {
    schemars::json_schema!({"type":"string","const":"session-rpc-response"})
}
pub(super) fn firecracker_version(_: &mut schemars::SchemaGenerator) -> Schema {
    schemars::json_schema!({"type":"string","const":super::FIRECRACKER_VERSION})
}
pub(super) fn guest_version(_: &mut schemars::SchemaGenerator) -> Schema {
    schemars::json_schema!({"type":"string","const":super::GUEST_PROTOCOL_VERSION})
}
