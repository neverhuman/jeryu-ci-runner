//! Compatibility of retained JSON references and explicit sparse admission.
use jeryu_runner_protocol::wire::v2::*;
use serde_json::json;
#[path = "support/managed_lease.rs"]
mod fixture;

#[test]
fn legacy_manifest_bytes_remain_stable_and_sparse_format_is_explicit() {
    let mut manifest = CheckpointManifest {
        format: CheckpointFormat::LegacyDenseV1,
        checkpoint_id: "a".repeat(32),
        context: fixture::lease().context,
        workspace: None,
        plaintext_bytes: 1024,
        plaintext_digest: fixture::digest(),
        ciphertext_digest: fixture::digest(),
        filesystem_flushed: true,
        created_at_unix_millis: 1000,
        expires_at_unix_millis: 1000 + 7 * 24 * 60 * 60 * 1000,
    };
    let legacy = manifest.to_json().unwrap();
    assert!(
        !serde_json::from_slice::<serde_json::Value>(&legacy)
            .unwrap()
            .as_object()
            .unwrap()
            .contains_key("format")
    );
    let recovered = CheckpointManifest::from_json(&legacy).unwrap();
    assert_eq!(recovered.format, CheckpointFormat::LegacyDenseV1);
    assert_eq!(recovered.to_json().unwrap(), legacy);
    manifest.format = CheckpointFormat::SparseV2;
    let sparse = manifest.to_json().unwrap();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&sparse).unwrap()["format"],
        "sparse_v2"
    );
    assert_eq!(CheckpointManifest::from_json(&sparse).unwrap(), manifest);
    let mut unknown = serde_json::from_slice::<serde_json::Value>(&sparse).unwrap();
    unknown["format"] = json!("unknown");
    assert!(CheckpointManifest::from_json(&serde_json::to_vec(&unknown).unwrap()).is_err());
}
