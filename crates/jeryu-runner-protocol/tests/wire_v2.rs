use jeryu_runner_protocol::wire::WireErrorCode;
use jeryu_runner_protocol::wire::v2::*;
use serde_json::json;

fn digest() -> String {
    format!("sha256:{}", "a".repeat(64))
}
fn artifact(id: &str) -> ArtifactIdentity {
    ArtifactIdentity {
        artifact_id: id.into(),
        digest: digest(),
    }
}
fn lease() -> SessionLease {
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

#[test]
fn image_class_profiles_and_mock_credential_denial_are_bound_and_required() {
    let original = lease();
    for profile in [
        RuntimeProfile::Fixture,
        RuntimeProfile::MockClaude,
        RuntimeProfile::MockCodex,
        RuntimeProfile::MockGrok,
    ] {
        let mut mock = original.clone();
        mock.runtime.profile_ids = vec![profile, RuntimeProfile::Shell];
        mock.profile_id = profile.id().into();
        mock.context.runtime_digest = runtime_digest(&mock.runtime).unwrap();
        mock.context.job_digest = mock.job_digest().unwrap();
        mock.validate().unwrap();
        mock.connection_bindings = vec![ConnectionBinding {
            provider: Provider::Codex,
            connection_id: "wrong-real-connection".into(),
            connection_generation: 1,
            mode: ConnectionMode::GatewayHelper,
        }];
        mock.context.job_digest = mock.job_digest().unwrap();
        assert!(mock.validate().is_err());
        mock.runtime.image_class = RuntimeImageClass::Production;
        assert!(mock.runtime.validate().is_err());
    }
    for field in ["image_class", "profile_ids"] {
        let mut value = serde_json::to_value(&original).unwrap();
        value["runtime"].as_object_mut().unwrap().remove(field);
        assert!(SessionLease::from_json(&serde_json::to_vec(&value).unwrap()).is_err());
    }
    let mut changed = original.clone();
    changed.profile_id = "mock-codex".into();
    changed.context.job_digest = changed.job_digest().unwrap();
    assert!(changed.validate().is_err());
    changed.runtime.profile_ids = vec![RuntimeProfile::Shell, RuntimeProfile::Fixture];
    assert!(changed.runtime.validate().is_err());
    changed.runtime.profile_ids = vec![
        RuntimeProfile::Fixture,
        RuntimeProfile::Fixture,
        RuntimeProfile::Shell,
    ];
    assert!(changed.runtime.validate().is_err());
    changed.runtime.profile_ids = vec![RuntimeProfile::Codex, RuntimeProfile::Shell];
    assert!(changed.runtime.validate().is_err());
}

#[test]
fn connection_bindings_are_required_canonical_and_in_the_job_identity() {
    let mut original = lease();
    original.profile_id = "codex".into();
    original.runtime.image_class = RuntimeImageClass::Production;
    original.runtime.profile_ids = vec![RuntimeProfile::Codex, RuntimeProfile::Shell];
    original.context.runtime_digest = runtime_digest(&original.runtime).unwrap();
    original.workspace = WorkspaceSource::GitBundle {
        bundle: artifact("bundle"),
        bundle_bytes: 512,
        main_revision: "b".repeat(40),
        base_revision: "a".repeat(40),
    };
    original.connection_bindings.push(ConnectionBinding {
        provider: Provider::Codex,
        connection_id: "connection".into(),
        connection_generation: 1,
        mode: ConnectionMode::GatewayHelper,
    });
    assert_ne!(original.context.job_digest, original.job_digest().unwrap());
    original.context.job_digest = original.job_digest().unwrap();
    original.validate().unwrap();
    let mut changed = original.clone();
    changed.connection_bindings[0].connection_generation += 1;
    assert!(changed.validate().is_err());
    changed.connection_bindings = vec![original.connection_bindings[0].clone(); 2];
    changed.context.job_digest = changed.job_digest().unwrap();
    assert!(changed.validate().is_err());
    let mut value = serde_json::to_value(&original).unwrap();
    value.as_object_mut().unwrap().remove("connection_bindings");
    assert!(SessionLease::from_json(&serde_json::to_vec(&value).unwrap()).is_err());
    let mut value = serde_json::to_value(&original).unwrap();
    value["connection_bindings"][0]["provider"] = json!("jekko");
    assert!(SessionLease::from_json(&serde_json::to_vec(&value).unwrap()).is_err());
    assert_eq!(
        original.signing_bytes().unwrap(),
        SessionLease::from_json(&original.to_json().unwrap())
            .unwrap()
            .signing_bytes()
            .unwrap()
    );
}

#[test]
fn managed_lease_has_no_backend_command_environment_or_credentials_override() {
    let original = lease();
    assert_eq!(
        SessionLease::from_json(&original.to_json().unwrap()).unwrap(),
        original
    );
    for field in [
        "runner_class",
        "command",
        "env",
        "trust_tier",
        "access_token",
    ] {
        let mut value = serde_json::to_value(&original).unwrap();
        value[field] = json!("native");
        assert_eq!(
            SessionLease::from_json(&serde_json::to_vec(&value).unwrap())
                .unwrap_err()
                .code(),
            WireErrorCode::InvalidJson
        );
    }
    for purpose in ["ci", "native", "managed-agent-without-vm"] {
        let mut value = serde_json::to_value(&original).unwrap();
        value["purpose"] = json!(purpose);
        assert!(SessionLease::from_json(&serde_json::to_vec(&value).unwrap()).is_err());
    }
}

#[test]
fn leases_bind_runtime_identity_peer_and_expiry() {
    let original = lease();
    original.validate_for_runner("node-1", 1, 1000).unwrap();
    for (peer, epoch, now) in [
        ("node-2", 1, 1000),
        ("node-1", 2, 1000),
        ("node-1", 1, 999),
        ("node-1", 1, 31000),
    ] {
        assert!(original.validate_for_runner(peer, epoch, now).is_err());
    }
    let mut changed = original.clone();
    changed.runtime.kernel.digest = format!("sha256:{}", "b".repeat(64));
    assert_eq!(
        changed.validate().unwrap_err().code(),
        WireErrorCode::ContextMismatch
    );
    let mut changed = original.clone();
    changed.context.environment_digest = format!("sha256:{}", "b".repeat(64));
    assert!(changed.validate().is_err());
    let mut changed = original.clone();
    changed.runtime.firecracker_version = "1.16.0".into();
    assert!(changed.validate().is_err());
    let mut changed = original.clone();
    changed.context.generation = 0;
    assert!(changed.validate().is_err());
    let mut changed = original.clone();
    changed.resources.memory_mib = 0;
    assert!(changed.validate().is_err());
    let mut changed = original;
    changed.expires_at_unix_millis = u64::MAX;
    assert!(changed.validate().is_err());
}

#[test]
fn workspace_sources_are_required_bound_to_the_job_and_cannot_downgrade_profiles() {
    let mut original = lease();
    original.workspace = WorkspaceSource::GitBundle {
        bundle: artifact("source-bundle"),
        bundle_bytes: 4096,
        main_revision: "b".repeat(40),
        base_revision: "c".repeat(40),
    };
    assert!(original.validate().is_err());
    original.context.job_digest = original.job_digest().unwrap();
    original.validate().unwrap();
    assert_eq!(
        SessionLease::from_json(&original.to_json().unwrap()).unwrap(),
        original
    );
    let mut changed = original.clone();
    if let WorkspaceSource::GitBundle { main_revision, .. } = &mut changed.workspace {
        *main_revision = "d".repeat(40);
    }
    assert!(changed.validate().is_err());
    let mut changed = original.clone();
    changed.context.source_revision = "d".repeat(40);
    assert!(changed.validate().is_err());
    let mut changed = original.clone();
    changed.resources.vcpus = original.resources.vcpus + 1;
    assert!(changed.validate().is_err());
    let mut changed = original.clone();
    changed.resources.git_limits.stdout_bytes *= 2;
    assert!(changed.validate().is_err());
    let mut changed = original.clone();
    changed.context.owner_id = "user/bob".into();
    assert!(changed.validate().is_err());
    let mut changed = original.clone();
    changed.workspace = WorkspaceSource::EmptyFixture;
    changed.profile_id = "codex".into();
    changed.context.job_digest = changed.job_digest().unwrap();
    assert!(changed.validate().is_err());
    let mut value = serde_json::to_value(original).unwrap();
    value.as_object_mut().unwrap().remove("workspace");
    assert!(SessionLease::from_json(&serde_json::to_vec(&value).unwrap()).is_err());
}

#[test]
fn rpc_replay_binds_the_expected_request_and_run_even_if_internal_frames_agree() {
    let context = lease().context;
    let request = SessionRpcRequest {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-rpc".into(),
        request_id: "rpc".into(),
        operation: SessionRpcOperation::Replay {
            actor: context.owner_id.clone(),
            session_id: context.session_id.clone(),
            generation: context.generation,
            channel_id: "shell".into(),
            cursor: 0,
            limit: 4,
        },
    };
    let frame = TerminalFrame {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-terminal".into(),
        session_id: context.session_id.clone(),
        generation: context.generation,
        run_id: context.run_id.clone(),
        channel_id: "shell".into(),
        sequence: 1,
        gap: false,
        bytes: vec![255],
    };
    let mut response = SessionRpcResponse {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-rpc-response".into(),
        request_id: Some(request.request_id.clone()),
        ok: true,
        result: Some(SessionRpcResult::Replay(vec![frame.clone()])),
        error: None,
    };
    response.validate_for(&request, &context).unwrap();
    for field in ["session", "generation", "run", "channel"] {
        let mut foreign = frame.clone();
        match field {
            "session" => foreign.session_id = "foreign".into(),
            "generation" => foreign.generation += 1,
            "run" => foreign.run_id = "foreign".into(),
            _ => foreign.channel_id = "agent".into(),
        }
        response.result = Some(SessionRpcResult::Replay(vec![foreign]));
        response.validate().unwrap();
        assert!(response.validate_for(&request, &context).is_err());
    }
    response.result = Some(SessionRpcResult::Replay(vec![]));
    response.validate_for(&request, &context).unwrap();
    response.request_id = Some("wrong".into());
    assert!(response.validate_for(&request, &context).is_err());
    response.request_id = Some(request.request_id.clone());
    response.result = Some(SessionRpcResult::Grant(GrantApplied { applied: true }));
    assert!(response.validate_for(&request, &context).is_err());
}

#[test]
fn terminal_preserves_binary_ansi_and_split_utf8_and_bounds_each_frame() {
    let mut frame = TerminalFrame {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-terminal".into(),
        session_id: "session-1".into(),
        generation: 1,
        run_id: "run-1".into(),
        channel_id: "agent".into(),
        sequence: 1,
        gap: false,
        bytes: vec![0, 255, 0x1b, b'[', b'3', b'1', b'm', 0xe2, 0x82],
    };
    assert_eq!(
        TerminalFrame::from_json(&frame.to_json().unwrap()).unwrap(),
        frame
    );
    frame.bytes = vec![0; MAX_TERMINAL_BYTES + 1];
    assert!(frame.validate().is_err());
    frame.bytes = vec![1];
    frame.gap = true;
    assert!(frame.validate().is_err());
    frame.bytes.clear();
    frame.validate().unwrap();
}

#[test]
fn controls_redact_prompts_and_acknowledgements_fence_generations() {
    let request = ControlRequest {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-control".into(),
        context: lease().context,
        request_id: "request-1".into(),
        channel_id: "agent".into(),
        controller_id: "user/alice".into(),
        control_lease_epoch: 1,
        control_sequence: 1,
        command: ControlCommand::Prompt {
            text: "sensitive-prompt-value".into(),
        },
    };
    assert!(!format!("{request:?}").contains("sensitive-prompt-value"));
    assert_eq!(
        ControlRequest::from_json(&request.to_json().unwrap()).unwrap(),
        request
    );
    let mut ack = ControlAck {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-control-ack".into(),
        context: request.context.clone(),
        request_id: request.request_id.clone(),
        channel_id: request.channel_id.clone(),
        state: ControlState::Rejected,
        reason: "unsupported-control".into(),
    };
    ack.validate_for(&request).unwrap();
    ack.context.generation += 1;
    assert!(ack.validate_for(&request).is_err());
}

#[test]
fn rpc_is_closed_and_validates_identity_generation_and_replay_bounds() {
    let original = SessionRpcRequest {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-rpc".into(),
        request_id: "rpc-1".into(),
        operation: SessionRpcOperation::Snapshot {
            actor: "user/alice".into(),
            session_id: "session-1".into(),
            generation: 1,
        },
    };
    SessionRpcRequest::from_json(&original.to_json().unwrap()).unwrap();
    let valid = serde_json::to_value(&original).unwrap();
    for operation in [
        json!({"action":"native","program":"/bin/sh"}),
        json!({"action":"snapshot","actor":"user/alice","session_id":"session-1","generation":1,"env":{"API_KEY":"secret"}}),
        json!({"action":"snapshot","actor":"","session_id":"session-1","generation":1}),
        json!({"action":"snapshot","actor":"user/alice","session_id":"session-1","generation":0}),
        json!({"action":"replay","actor":"user/alice","session_id":"session-1","generation":1,"channel_id":"shell","cursor":0,"limit":5}),
    ] {
        let mut changed = valid.clone();
        changed["operation"] = operation;
        assert!(SessionRpcRequest::from_json(&serde_json::to_vec(&changed).unwrap()).is_err());
    }
    for id in ["".into(), "a".repeat(129), "secret\n".into()] {
        let mut changed = original.clone();
        changed.request_id = id;
        assert!(changed.validate().is_err());
    }
    let mut changed = valid;
    changed["message_type"] = json!("session-lease");
    assert!(SessionRpcRequest::from_json(&serde_json::to_vec(&changed).unwrap()).is_err());
}

#[test]
fn rpc_separates_principal_from_client_and_redacts_prompt_material() {
    let control = ControlRequest {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-control".into(),
        context: lease().context,
        request_id: "control-1".into(),
        channel_id: "agent".into(),
        controller_id: "attachment-123".into(),
        control_lease_epoch: 1,
        control_sequence: 1,
        command: ControlCommand::Prompt {
            text: "sensitive-prompt-value".into(),
        },
    };
    let mut request = SessionRpcRequest {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-rpc".into(),
        request_id: "rpc-1".into(),
        operation: SessionRpcOperation::Control {
            actor: "user/bob".into(),
            request: Box::new(control),
        },
    };
    // Structural validation does not authorize Bob to use this client. The
    // service checks actor AND attachment AND epoch against the active lease.
    request.validate().unwrap();
    if let SessionRpcOperation::Control { actor, .. } = &mut request.operation {
        *actor = "user/alice".into();
    }
    request.validate().unwrap();
    assert!(!format!("{request:?}").contains("sensitive-prompt-value"));
}

#[test]
fn checkpoint_references_bind_jobs_and_cannot_supply_host_paths_or_keys() {
    let mut original = lease();
    let reference = CheckpointReference {
        checkpoint_id: "a".repeat(32),
        manifest_digest: digest(),
    };
    original.checkpoint = Some(reference.clone());
    assert!(original.validate().is_err());
    original.context.job_digest = original.job_digest().unwrap();
    original.validate().unwrap();
    for id in [
        "../workspace".into(),
        "/var/lib/workspace".into(),
        "A".repeat(32),
        "a".repeat(33),
    ] {
        let mut changed = reference.clone();
        changed.checkpoint_id = id;
        assert!(changed.validate().is_err());
    }
    let mut value = serde_json::to_value(&reference).unwrap();
    value["key"] = json!("secret");
    assert!(CheckpointReference::from_json(&serde_json::to_vec(&value).unwrap()).is_err());
    let mut manifest = CheckpointManifest {
        checkpoint_id: reference.checkpoint_id,
        context: original.context,
        workspace: None,
        plaintext_bytes: 1024,
        plaintext_digest: digest(),
        ciphertext_digest: digest(),
        filesystem_flushed: true,
        created_at_unix_millis: 1000,
        expires_at_unix_millis: 1000 + 7 * 24 * 60 * 60 * 1000,
    };
    manifest.validate().unwrap();
    manifest.expires_at_unix_millis += 1;
    assert!(manifest.validate().is_err());
}
