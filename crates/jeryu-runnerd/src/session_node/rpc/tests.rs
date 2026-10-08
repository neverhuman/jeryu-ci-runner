use super::*;
use http_body_util::BodyExt;
use hyper::StatusCode;
use jeryu_runner_protocol::wire::v2::SessionRpcResponse;
use sha2::{Digest, Sha256};
use std::os::unix::fs::MetadataExt;

#[tokio::test]
async fn host_write_parser_denial_and_response_preserve_sentinel_without_session_lookup() {
    let root = std::env::temp_dir().join(format!("host-write-policy-{}", std::process::id()));
    std::fs::create_dir(&root).unwrap();
    let sentinel = root.join("sentinel");
    std::fs::write(&sentinel, b"host sentinel unchanged").unwrap();
    let metadata = std::fs::metadata(&sentinel).unwrap();
    let digest = Sha256::digest(std::fs::read(&sentinel).unwrap());
    for path in [
        sentinel.to_string_lossy().into_owned(),
        "invalid\0host-path".into(),
        root.join("missing/child").to_string_lossy().into_owned(),
    ] {
        let raw = serde_json::to_vec(&serde_json::json!({
            "protocol_version": PROTOCOL_VERSION, "message_type": "session-rpc",
            "request_id": "host-write-probe", "operation": {
                "action": "host-write", "actor": "user/alice", "session_id": "missing-session",
                "generation": 1, "path": path, "content_b64": "opaque!not-decoded"
            }
        }))
        .unwrap();
        let request = RpcRequest::from_json(&raw).unwrap();
        assert!(!format!("{request:?}").contains("opaque"));
        let denied = deny_host_write(&request).unwrap_err();
        assert_eq!(denied.code(), "host_write_denied");
        let response = super::super::serve::error_for(
            StatusCode::CONFLICT,
            denied.code(),
            Some(request.request_id.clone()),
        );
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let response = SessionRpcResponse::from_json(&bytes).unwrap();
        assert!(!response.ok);
        assert_eq!(response.request_id.as_deref(), Some("host-write-probe"));
        assert_eq!(response.error.as_ref().unwrap().code, "host_write_denied");
        let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value["error_code"], "host_write_denied");
        let after = std::fs::metadata(&sentinel).unwrap();
        assert_eq!((metadata.dev(), metadata.ino()), (after.dev(), after.ino()));
        assert_eq!(digest, Sha256::digest(std::fs::read(&sentinel).unwrap()));
        assert!(!root.join("missing").exists());
        let mut inconsistent = value.clone();
        inconsistent["error"]["code"] = "session_rpc_invalid".into();
        assert!(
            SessionRpcResponse::from_json(&serde_json::to_vec(&inconsistent).unwrap()).is_err()
        );
        inconsistent = value;
        inconsistent.as_object_mut().unwrap().remove("error_code");
        assert!(
            SessionRpcResponse::from_json(&serde_json::to_vec(&inconsistent).unwrap()).is_err()
        );
    }
    std::fs::remove_file(sentinel).unwrap();
    std::fs::remove_dir(root).unwrap();
}
