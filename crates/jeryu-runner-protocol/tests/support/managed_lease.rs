use jeryu_runner_protocol::wire::v2::*;

pub fn digest() -> String {
    format!("sha256:{}", "a".repeat(64))
}
pub fn artifact(id: &str) -> ArtifactIdentity {
    ArtifactIdentity {
        artifact_id: id.into(),
        digest: digest(),
    }
}
pub fn lease() -> SessionLease {
    let runtime = RuntimeManifest {
        image_class: RuntimeImageClass::Test,
        profile_ids: vec![RuntimeProfile::Fixture, RuntimeProfile::Shell],
        firecracker_version: FIRECRACKER_VERSION.into(),
        guest_protocol_version: GUEST_PROTOCOL_VERSION.into(),
        architecture: RuntimeArchitecture::X86_64,
        kernel_version: "6.18.51".into(),
        firecracker: artifact("firecracker"),
        jailer: artifact("jailer"),
        kernel: artifact("kernel"),
        rootfs: artifact("rootfs"),
        guestd: artifact("guestd"),
        agent: artifact("fixture"),
        toolchain: artifact("toolchain"),
        environment_digest: digest(),
        recipe_digest: digest(),
        policy_revision: digest(),
        snapshot_compatibility: "fixture-v1".into(),
    };
    let mut lease = SessionLease {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-lease".into(),
        purpose: ManagedPurpose::ManagedAgent,
        context: SessionContext {
            session_id: "session-1".into(),
            generation: 1,
            run_id: "run-1".into(),
            owner_id: "user/alice".into(),
            repository: "alice/repo".into(),
            source_revision: "a".repeat(40),
            runner_id: "node-1".into(),
            runner_epoch: 1,
            lease_id: "lease-1".into(),
            lease_epoch: 1,
            job_digest: digest(),
            environment_digest: digest(),
            runtime_digest: runtime_digest(&runtime).unwrap(),
            policy_revision: digest(),
        },
        profile_id: "fixture".into(),
        workspace: WorkspaceSource::EmptyFixture,
        checkpoint: None,
        connection_bindings: vec![],
        signature: "0".repeat(128),
        runtime,
        resources: SessionResources::default(),
        issued_at_unix_millis: 1000,
        expires_at_unix_millis: 31000,
    };
    lease.context.job_digest = lease.job_digest().unwrap();
    lease
}
