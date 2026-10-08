use super::*;
use crate::wire::v2::RelayHeaderName;
use base64ct::{Base64, Encoding};
const INVALID: RelayErrorCode = RelayErrorCode::RelayStreamInvalid;

pub(super) fn id_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
    serde_json::json!({"type":"string","minLength":1,"maxLength":128,
        "pattern":"^[A-Za-z0-9]([A-Za-z0-9._:/-]*[A-Za-z0-9])?$"})
    .try_into()
    .unwrap()
}
pub(super) fn body_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
    serde_json::json!({"type":"string","minLength":4,"maxLength":43692,
        "pattern":"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"})
    .try_into()
    .unwrap()
}

pub(super) fn authorization<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<String>, D::Error> {
    String::deserialize(deserializer).map(Some)
}

pub fn metadata(path: &str, headers: &[RelayHeader]) -> bool {
    path.len() <= 2048
        && path.starts_with('/')
        && path.len() > 1
        && path.is_ascii()
        && !path.bytes().any(|b| b <= 32 || b == 127)
        && !path.contains(['#', '\\', '@', '?', '%'])
        && path[1..].split('/').all(|p| !matches!(p, "" | "." | ".."))
        && header_values(headers, false)
}
fn header_values(headers: &[RelayHeader], response: bool) -> bool {
    headers.len() <= if response { 1 } else { 2 }
        && headers.iter().enumerate().all(|(index, header)| {
            (!response || header.name == RelayHeaderName::ContentType)
                && !header.value.is_empty()
                && header.value.len() <= 256
                && header.value.is_ascii()
                && !header.value.bytes().any(|b| b < 32 || b == 127)
                && !headers[..index].iter().any(|h| h.name == header.name)
        })
}
fn id(value: &str) -> Result<(), RelayErrorCode> {
    crate::wire::v2::validate_control_identity(value, value).map_err(|_| INVALID)
}
pub fn body_bytes(value: &str) -> Result<Vec<u8>, RelayErrorCode> {
    // Reject before allocating. Canonical padded standard base64 only.
    if value.is_empty() || value.len() > 43692 {
        return Err(INVALID);
    }
    let bytes = Base64::decode_vec(value).map_err(|_| INVALID)?;
    if bytes.is_empty() || bytes.len() > MAX_BODY_BYTES || Base64::encode_string(&bytes) != value {
        return Err(INVALID);
    }
    Ok(bytes)
}
impl GuestRelayFrame {
    pub fn validate(&self) -> Result<(), RelayErrorCode> {
        id(self.request_id())?;
        match self {
            Self::Open {
                path,
                headers,
                authorization,
                ..
            } => {
                if authorization.is_some() {
                    return Err(RelayErrorCode::GuestAuthorizationRejected);
                }
                if !metadata(path, headers) {
                    return Err(INVALID);
                }
            }
            Self::RequestBody { seq, bytes_b64, .. } => {
                if *seq == 0 {
                    return Err(INVALID);
                }
                body_bytes(bytes_b64)?;
            }
            Self::Ack { through_seq: 0, .. } => return Err(INVALID),
            Self::Ack { .. } | Self::RequestEnd { .. } | Self::Cancel { .. } => (),
        }
        Ok(())
    }
}
impl NodeRelayFrame {
    pub fn validate(&self) -> Result<(), RelayErrorCode> {
        id(self.request_id())?;
        match self {
            Self::Head {
                status, headers, ..
            } => {
                if !(100..=599).contains(status) || !header_values(headers, true) {
                    return Err(INVALID);
                }
            }
            Self::ResponseBody { seq, bytes_b64, .. } => {
                if *seq == 0 {
                    return Err(INVALID);
                }
                body_bytes(bytes_b64)?;
            }
            Self::Ack { through_seq: 0, .. } => return Err(INVALID),
            Self::Ack { .. } | Self::ResponseEnd { .. } | Self::Error { .. } => (),
        }
        Ok(())
    }
}
