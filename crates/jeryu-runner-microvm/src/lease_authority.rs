//! Signed control-plane admission is independent of authenticated transport.
use ed25519_dalek::{Signature, VerifyingKey};
use jeryu_runner_core::{RunnerError, RunnerResult};
use jeryu_runner_protocol::wire::v2::SessionLease;

pub fn verify(lease: &SessionLease, enrolled_key: &[u8; 32]) -> RunnerResult<()> {
    lease
        .validate()
        .map_err(|_| failed("microvm_lease_invalid"))?;
    let key = VerifyingKey::from_bytes(enrolled_key)
        .map_err(|_| failed("microvm_lease_authority_invalid"))?;
    let signature = Signature::from_slice(
        &hex::decode(&lease.signature).map_err(|_| failed("microvm_lease_signature_invalid"))?,
    )
    .map_err(|_| failed("microvm_lease_signature_invalid"))?;
    key.verify_strict(
        &lease
            .signing_bytes()
            .map_err(|_| failed("microvm_lease_invalid"))?,
        &signature,
    )
    .map_err(|_| failed("microvm_lease_signature_invalid"))
}
fn failed(code: &'static str) -> RunnerError {
    RunnerError::new(code, "signed execution lease rejected")
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};
    use jeryu_runner_protocol::wire::v2::*;
    fn fixture() -> SessionLease {
        let digest = format!("sha256:{}", "a".repeat(64));
        let artifact = ArtifactIdentity {
            artifact_id: "fixture".into(),
            digest: digest.clone(),
        };
        let runtime = RuntimeManifest {
            image_class: RuntimeImageClass::Production,
            profile_ids: vec![RuntimeProfile::Codex, RuntimeProfile::Shell],
            firecracker_version: FIRECRACKER_VERSION.into(),
            guest_protocol_version: GUEST_PROTOCOL_VERSION.into(),
            architecture: RuntimeArchitecture::X86_64,
            kernel_version: "6.18.51".into(),
            firecracker: artifact.clone(),
            jailer: artifact.clone(),
            kernel: artifact.clone(),
            rootfs: artifact.clone(),
            guestd: artifact.clone(),
            agent: artifact.clone(),
            toolchain: artifact,
            environment_digest: digest.clone(),
            recipe_digest: digest.clone(),
            policy_revision: digest.clone(),
            snapshot_compatibility: "fixture".into(),
        };
        SessionLease {
            protocol_version: PROTOCOL_VERSION.into(),
            message_type: "session-lease".into(),
            purpose: ManagedPurpose::ManagedAgent,
            context: SessionContext {
                session_id: "session".into(),
                generation: 1,
                run_id: "run".into(),
                owner_id: "user/alice".into(),
                repository: "test/repo".into(),
                source_revision: "a".repeat(40),
                runner_id: "node".into(),
                runner_epoch: 1,
                lease_id: "lease".into(),
                lease_epoch: 1,
                job_digest: digest.clone(),
                environment_digest: digest.clone(),
                runtime_digest: runtime_digest(&runtime).unwrap(),
                policy_revision: digest,
            },
            profile_id: "codex".into(),
            workspace: WorkspaceSource::GitBundle {
                bundle: ArtifactIdentity {
                    artifact_id: "bundle".into(),
                    digest: format!("sha256:{}", "a".repeat(64)),
                },
                bundle_bytes: 512,
                main_revision: "b".repeat(40),
                base_revision: "a".repeat(40),
            },
            checkpoint: None,
            connection_bindings: vec![ConnectionBinding {
                provider: Provider::Codex,
                connection_id: "connection".into(),
                connection_generation: 1,
                mode: ConnectionMode::GatewayHelper,
            }],
            runtime,
            resources: SessionResources::default(),
            issued_at_unix_millis: 1000,
            expires_at_unix_millis: 31000,
            signature: "0".repeat(128),
        }
    }
    #[test]
    fn enrolled_authority_and_every_mutated_lease_field_are_verified_independently_of_transport() {
        // Deterministic unit-test authority; never a production or canary key.
        let authority = SigningKey::from_bytes(&[27; 32]);
        let mut lease = fixture();
        lease.context.job_digest = lease.job_digest().unwrap();
        lease.signature = hex::encode(authority.sign(&lease.signing_bytes().unwrap()).to_bytes());
        verify(&lease, &authority.verifying_key().to_bytes()).unwrap();
        assert!(
            verify(
                &lease,
                &SigningKey::from_bytes(&[28; 32]).verifying_key().to_bytes()
            )
            .is_err()
        );
        for mutation in 0..8 {
            let mut changed = lease.clone();
            match mutation {
                0 => changed.context.owner_id = "user/bob".into(),
                1 => changed.context.runner_epoch += 1,
                2 => changed.context.lease_epoch += 1,
                3 => changed.expires_at_unix_millis += 1,
                4 => changed.connection_bindings[0].connection_generation += 1,
                5 => changed.connection_bindings[0].mode = ConnectionMode::QualifiedRamToken,
                6 => {
                    changed.checkpoint = Some(CheckpointReference {
                        checkpoint_id: "a".repeat(32),
                        manifest_digest: format!("sha256:{}", "b".repeat(64)),
                    })
                }
                _ => changed.signature = "0".repeat(128),
            }
            changed.context.job_digest = changed.job_digest().unwrap();
            changed.validate().unwrap();
            assert_eq!(
                verify(&changed, &authority.verifying_key().to_bytes())
                    .unwrap_err()
                    .code(),
                "microvm_lease_signature_invalid"
            );
        }
        assert!(lease.validate_for_runner("node", 1, 1001).is_ok());
        assert!(lease.validate_for_runner("node", 2, 1001).is_err());
        assert!(lease.validate_for_runner("node", 1, 31000).is_err());
    }
}
