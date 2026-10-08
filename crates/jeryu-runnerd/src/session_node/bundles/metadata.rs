use super::*;
use hyper::HeaderMap;
use jeryu_runner_protocol::wire::v2::{PROTOCOL_VERSION, SessionRpcError, SessionRpcResponse};

pub(super) fn content_length(headers: &HeaderMap) -> Result<u64, &'static str> {
    if headers
        .get("content-type")
        .and_then(|value| value.to_str().ok())
        != Some("application/octet-stream")
        || headers.get_all("content-type").iter().count() != 1
        || headers.contains_key("transfer-encoding")
        || headers.get_all("content-length").iter().count() != 1
    {
        return Err("bundle_http_headers_invalid");
    }
    let value = headers
        .get("content-length")
        .and_then(|value| value.to_str().ok())
        .ok_or("bundle_http_headers_invalid")?;
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err("bundle_http_headers_invalid");
    }
    let size = value.parse::<u64>().map_err(|_| "bundle_length_invalid")?;
    if !(517..=((1 << 30) + 16388)).contains(&size) {
        return Err("bundle_length_invalid");
    }
    Ok(size)
}
pub(super) fn decode(
    bytes: &[u8],
    total: u64,
) -> Result<BundleUpload, (&'static str, Option<String>)> {
    let upload: BundleUpload =
        serde_json::from_slice(bytes).map_err(|_| ("bundle_metadata_invalid", None))?;
    let id = SessionRpcResponse {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-rpc-response".into(),
        request_id: Some(upload.request_id.clone()),
        ok: false,
        error_code: None,
        result: None,
        error: Some(SessionRpcError {
            code: "bundle_upload_invalid".into(),
        }),
    }
    .validate()
    .ok()
    .map(|()| upload.request_id.clone());
    upload
        .validate()
        .map_err(|_| ("bundle_upload_invalid", id.clone()))?;
    if total != 4 + bytes.len() as u64 + upload.stored_bytes {
        return Err(("bundle_length_invalid", id));
    }
    Ok(upload)
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn invalid_privileged_metadata_and_length_cannot_reserve_registry_space() {
        let mut value = json!({"protocol_version":PROTOCOL_VERSION,"message_type":"bundle-upload","request_id":"upload","role":"source_bundle","digest":format!("sha256:{}", "a".repeat(64)),"stored_bytes":512,"bundle_bytes":501});
        let bytes = serde_json::to_vec(&value).unwrap();
        assert!(decode(&bytes, 4 + bytes.len() as u64 + 512).is_ok());
        assert_eq!(
            decode(&bytes, 4 + bytes.len() as u64 + 513).unwrap_err(),
            ("bundle_length_invalid", Some("upload".into()))
        );
        value["stored_bytes"] = json!(u64::MAX);
        assert_eq!(
            decode(&serde_json::to_vec(&value).unwrap(), 1024)
                .unwrap_err()
                .1,
            Some("upload".into())
        );
        value["role"] = json!("firecracker");
        assert!(decode(&serde_json::to_vec(&value).unwrap(), 1024).is_err());
        value["role"] = json!("source_bundle");
        value["path"] = json!("/etc/shadow");
        assert!(decode(&serde_json::to_vec(&value).unwrap(), 1024).is_err());
    }
    #[test]
    fn chunked_duplicate_or_unbounded_content_length_is_rejected() {
        let mut headers = HeaderMap::new();
        headers.insert("content-type", "application/octet-stream".parse().unwrap());
        headers.insert("content-length", "1024".parse().unwrap());
        assert_eq!(content_length(&headers).unwrap(), 1024);
        headers.append("content-length", "1024".parse().unwrap());
        assert!(content_length(&headers).is_err());
        headers.remove("content-length");
        headers.insert("content-length", "18446744073709551615".parse().unwrap());
        assert!(content_length(&headers).is_err());
        headers.insert("content-length", "1024".parse().unwrap());
        headers.insert("transfer-encoding", "chunked".parse().unwrap());
        assert!(content_length(&headers).is_err());
    }
}
