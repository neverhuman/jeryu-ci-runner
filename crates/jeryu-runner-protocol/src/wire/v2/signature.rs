//! K1 canonical signing representation. No signing keys belong in this crate.
use super::SessionLease;
use crate::wire::validation::{WireError, WireErrorCode};
use serde_json::Value;
use std::collections::BTreeMap;

impl SessionLease {
    /// The signature field is excluded. Every other field, including assignment
    /// and expiry, is signed. Keys sort recursively; arrays preserve their order.
    /// This deliberately supports only the integer JSON values used by leases.
    pub fn signing_bytes(&self) -> Result<Vec<u8>, WireError> {
        let mut value = serde_json::to_value(self).map_err(|_| invalid())?;
        value
            .as_object_mut()
            .ok_or_else(invalid)?
            .remove("signature");
        let mut bytes = b"jeryu.runner.lease.v2.1\0".to_vec();
        canonical(&value, &mut bytes)?;
        Ok(bytes)
    }
}
fn canonical(value: &Value, bytes: &mut Vec<u8>) -> Result<(), WireError> {
    match value {
        Value::Object(map) => {
            bytes.push(b'{');
            for (index, (key, value)) in map.iter().collect::<BTreeMap<_, _>>().iter().enumerate() {
                if index > 0 {
                    bytes.push(b',');
                }
                bytes.extend(serde_json::to_vec(key).map_err(|_| invalid())?);
                bytes.push(b':');
                canonical(value, bytes)?;
            }
            bytes.push(b'}');
        }
        Value::Array(values) => {
            bytes.push(b'[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    bytes.push(b',');
                }
                canonical(value, bytes)?;
            }
            bytes.push(b']');
        }
        Value::Number(number) if !(number.is_i64() || number.is_u64()) => return Err(invalid()),
        _ => bytes.extend(serde_json::to_vec(value).map_err(|_| invalid())?),
    }
    Ok(())
}
fn invalid() -> WireError {
    WireError::new(WireErrorCode::InvalidJson, "lease_signature")
}
