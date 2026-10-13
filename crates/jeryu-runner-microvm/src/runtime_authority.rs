//! Admission trusts one enrolled role, not whichever key verifies a signature.
use crate::artifacts::denied;
use ed25519_dalek::{Signature, VerifyingKey};
use jeryu_runner_core::RunnerResult;
use jeryu_runner_protocol::wire::v2::{RuntimeImageClass, RuntimeManifest};

/// The node's release check, the first step of `VerifiedRuntime::admit`: a
/// production manifest whose `to_json()` bytes the enrolled release key signed.
/// It admits nothing by itself; release tooling runs it before installing.
pub fn production(
    manifest: &RuntimeManifest,
    signature: &[u8; 64],
    release_key: &[u8; 32],
) -> RunnerResult<()> {
    if manifest.image_class != RuntimeImageClass::Production {
        return Err(denied("runtime_test_image_denied"));
    }
    verify(manifest, signature, release_key)
}
pub(crate) fn test(
    manifest: &RuntimeManifest,
    signature: &[u8; 64],
    release_key: &[u8; 32],
    test_key: &[u8; 32],
) -> RunnerResult<()> {
    if manifest.image_class != RuntimeImageClass::Test {
        return Err(denied("runtime_production_image_denied"));
    }
    VerifyingKey::from_bytes(release_key).map_err(|_| denied("runtime_signature_invalid"))?;
    if release_key == test_key {
        return Err(denied("runtime_test_authority_not_distinct"));
    }
    verify(manifest, signature, test_key)
}
fn verify(manifest: &RuntimeManifest, signature: &[u8; 64], key: &[u8; 32]) -> RunnerResult<()> {
    let canonical = manifest
        .to_json()
        .map_err(|_| denied("runtime_manifest_invalid"))?;
    VerifyingKey::from_bytes(key)
        .map_err(|_| denied("runtime_signature_invalid"))?
        .verify_strict(&canonical, &Signature::from_bytes(signature))
        .map_err(|_| denied("runtime_signature_invalid"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::artifacts::VerifiedRuntime;
    use ed25519_dalek::{Signer, SigningKey};
    use jeryu_runner_protocol::wire::v2::*;
    use std::path::Path;
    #[test]
    fn test_and_release_authorities_cannot_be_substituted_even_with_valid_signatures() {
        let artifact = ArtifactIdentity {
            artifact_id: "synthetic".into(),
            digest: format!("sha256:{}", "a".repeat(64)),
        };
        let mut manifest = RuntimeManifest {
            image_class: RuntimeImageClass::Test,
            profile_ids: vec![RuntimeProfile::Fixture, RuntimeProfile::Shell],
            firecracker_version: FIRECRACKER_VERSION.into(),
            guest_protocol_version: GUEST_PROTOCOL_VERSION.into(),
            architecture: RuntimeArchitecture::X86_64,
            kernel_version: "synthetic".into(),
            firecracker: artifact.clone(),
            jailer: artifact.clone(),
            kernel: artifact.clone(),
            rootfs: artifact.clone(),
            guestd: artifact.clone(),
            agent: artifact.clone(),
            toolchain: artifact.clone(),
            environment_digest: artifact.digest.clone(),
            recipe_digest: artifact.digest.clone(),
            policy_revision: artifact.digest,
            snapshot_compatibility: "synthetic".into(),
        };
        let release = SigningKey::from_bytes(&[31; 32]);
        let fixture = SigningKey::from_bytes(&[32; 32]);
        let other = SigningKey::from_bytes(&[33; 32]);
        let release_public = release.verifying_key().to_bytes();
        let test_public = fixture.verifying_key().to_bytes();
        let signature = fixture.sign(&manifest.to_json().unwrap()).to_bytes();
        test(&manifest, &signature, &release_public, &test_public).unwrap();
        assert_eq!(
            production(&manifest, &signature, &release_public)
                .unwrap_err()
                .code(),
            "runtime_test_image_denied"
        );
        assert_eq!(
            test(&manifest, &signature, &test_public, &test_public)
                .unwrap_err()
                .code(),
            "runtime_test_authority_not_distinct"
        );
        assert!(
            test(
                &manifest,
                &signature,
                &release_public,
                &other.verifying_key().to_bytes()
            )
            .is_err()
        );
        let signature = release.sign(&manifest.to_json().unwrap()).to_bytes();
        assert!(test(&manifest, &signature, &release_public, &test_public).is_err());
        manifest.image_class = RuntimeImageClass::Production;
        manifest.profile_ids = vec![RuntimeProfile::Shell];
        let signature = release.sign(&manifest.to_json().unwrap()).to_bytes();
        production(&manifest, &signature, &release_public).unwrap();
        assert_eq!(
            test(&manifest, &signature, &release_public, &test_public)
                .unwrap_err()
                .code(),
            "runtime_production_image_denied"
        );
        let signature = fixture.sign(&manifest.to_json().unwrap()).to_bytes();
        assert!(production(&manifest, &signature, &release_public).is_err());
        manifest.profile_ids = vec![RuntimeProfile::Codex, RuntimeProfile::Shell];
        let signature = release.sign(&manifest.to_json().unwrap()).to_bytes();
        assert_eq!(
            VerifiedRuntime::admit(
                manifest,
                &signature,
                &release_public,
                Path::new("/not-an-enrolled-registry")
            )
            .unwrap_err()
            .code(),
            "runtime_profile_unqualified"
        );
    }
}
