//! Real KVM development evidence through managed dispatch and SessionService.
//! Uses a separate fixture signing authority; never qualifies a release/provider.
#[path = "live_session/authority.rs"]
mod authority;
#[path = "live_session/checkpoint.rs"]
mod checkpoint;
#[path = "live_session/concurrent.rs"]
mod concurrent;
#[path = "live_session/lifecycle.rs"]
mod lifecycle;
#[path = "live_session/recovery.rs"]
mod recovery;
#[path = "live_session/resources.rs"]
mod resources;
#[path = "live_session/source.rs"]
mod source;
#[path = "live_session/terminal.rs"]
mod terminal;
use jeryu_runner_core::receipt::now_ms;
use jeryu_runner_microvm::{NodeConfig, artifacts::VerifiedRuntime};
use jeryu_runner_protocol::wire::v2::*;
use jeryu_runnerd::{
    dispatch::DispatchEngine,
    sessions::{AccessGrant, RuntimePhase, SessionEvent, SessionHandle, SessionService},
};
use std::{
    fs,
    path::Path,
    sync::Arc,
    time::{Duration, Instant},
};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const ROOT: &str = "/var/lib/jeryu-live-fixture";
const OWNER: &str = "user/fixture-owner";

fn main() -> Result<()> {
    let root = Path::new(ROOT);
    let manifest = RuntimeManifest::from_json(&fs::read(root.join("runtime.json"))?)?;
    let signature = fs::read(root.join("runtime.sig"))?
        .try_into()
        .map_err(|_| "signature length")?;
    let key = fs::read(root.join("fixture.pub"))?
        .try_into()
        .map_err(|_| "key length")?;
    let runtime = Arc::new(VerifiedRuntime::admit(
        manifest.clone(),
        &signature,
        &key,
        &root.join("artifacts"),
    )?);
    let mut lease = fixture_lease(manifest)?;
    let mode = std::env::args().nth(1).unwrap_or_else(|| "empty".into());
    source::configure(
        &mut lease,
        if mode == "missing-cgroup"
            || mode == "concurrent"
            || mode == "rpc-lease"
            || mode == "checkpoint"
            || mode == "cleanup-fixture"
            || mode == "corrupt-record"
            || mode == "resource-limits"
            || mode == "control-terminal"
            || mode == "guestd-mismatch"
        {
            "empty"
        } else if [
            "checkpoint-main",
            "graph-override",
            "idle-stop",
            "runtime-stop",
            "direct-stop",
        ]
        .contains(&mode.as_str())
        {
            "main-sync"
        } else {
            &mode
        },
    )?;
    authority::sign(&mut lease)?;
    let context = lease.context.clone();
    if mode == "rpc-lease" {
        println!("{}", String::from_utf8(lease.to_json()?)?);
        return Ok(());
    }
    let node = NodeConfig {
        runner_id: "fixture-node".into(),
        runner_epoch: 1,
        control_plane_lease_key: fs::read(root.join("lease-authority.pub"))?
            .try_into()
            .map_err(|_| "fixture lease public key length")?,
        state_dir: root.join("node"),
        capacity: 4,
        cpu_budget_vcpus: 4,
        memory_budget_mib: 2048,
        disk_budget_gib: 16,
    }
    .open()?;
    if mode == "cleanup-fixture" {
        return recovery::discard_checkpoints(&node);
    }
    let service = SessionService::new(node.clone(), runtime);
    if ["idle-stop", "runtime-stop", "direct-stop"].contains(&mode.as_str()) {
        return lifecycle::run(&service, &node, lease, &mode);
    }
    if mode == "resource-limits" {
        resources::deny_cpu(&service, &lease)?;
    }
    if mode == "checkpoint" || mode == "checkpoint-main" {
        return checkpoint::run(&service, &node, lease, mode == "checkpoint-main");
    }
    if mode == "concurrent" {
        return concurrent::run(&service.with_owner_limit(3)?, &node, lease);
    }
    let started = Instant::now();
    let result = DispatchEngine::new().dispatch_managed_session(&service, lease);
    if mode == "guestd-mismatch" {
        match result {
            Err(error) if error.to_string().contains("guestd_identity_mismatch") => (),
            _ => return Err("booted guestd identity was not rejected".into()),
        }
        if fs::read_dir(root.join("node/records"))?.next().is_some() {
            return Err("mismatched boot retained a VM resource".into());
        }
        println!(
            "booted_guestd_mismatch=passed scope=development ready=false agent_started=false vm_destroyed=true"
        );
        return Ok(());
    }
    if mode == "mismatch" {
        let expected = "guest_source_revision_mismatch";
        match result {
            Err(error) if error.to_string().contains(expected) => (),
            _ => return Err("main-sync failure was not rejected before dispatch".into()),
        }
        if fs::read_dir(root.join("node/records"))?.next().is_some() {
            return Err("failed main synchronization retained runtime resources".into());
        }
        println!("main_sync_failure=passed mode={mode} dispatched=false vm_destroyed=true");
        return Ok(());
    }
    let handle = result?;
    if mode == "control-terminal" {
        return terminal::run(&handle, &context, &node);
    }
    if mode == "resource-limits" {
        resources::verify_sparse(&context)?;
    }
    if mode == "conflict" {
        return source::conflict(&handle, &context, &node);
    }
    if mode == "graph-override" {
        return source::graph_override(&handle, &context, &node);
    }
    println!(
        "managed_session_handshake_ms={}",
        started.elapsed().as_millis()
    );
    if handle.snapshot("other-user").is_ok()
        || service
            .get("other-user", &context.session_id, context.generation)
            .is_ok()
    {
        return Err("cross-user session access allowed".into());
    }
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let snapshot = handle.snapshot(OWNER)?;
        if snapshot.phase != RuntimePhase::Running {
            return Err("session failed before guest build".into());
        }
        if let Some(agent) = snapshot
            .channels
            .iter()
            .find(|channel| channel.channel_id == "agent")
            && agent.exited
        {
            if agent.exit_code != Some(0) {
                return Err("guest build failed".into());
            }
            break;
        }
        if Instant::now() > deadline {
            return Err("guest build timeout".into());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    handle.grant(OWNER, "fixture-viewer", Some(AccessGrant::Viewer))?;
    if mode == "resource-limits" {
        resources::verify_backpressure(&handle, &context)?;
    }
    if mode == "corrupt-record" {
        return recovery::corrupt_record(&service, &node, &handle, &context);
    }
    if mode == "main-sync" {
        source::verify(&handle, &context)?;
    }
    let viewer = handle.subscribe("fixture-viewer", "shell")?;
    if handle
        .acquire_control("fixture-viewer", "viewer-client", &[], false)
        .is_ok()
    {
        return Err("viewer obtained input lease".into());
    }
    apply(
        &handle,
        &context,
        ControlCommand::Resize { rows: 37, cols: 93 },
    )?;
    apply(&handle, &context, ControlCommand::Input {
        bytes: b"test -f main.c && test -x build && test ! -e /var/lib/jeryu-live-fixture/host-only-sentinel && stty size && printf '\\nSERVICE_SHELL_VERIFIED\\n'\n".to_vec(),
    })?;
    let output = wait_output(&handle, b"SERVICE_SHELL_VERIFIED\r", Duration::from_secs(5))?;
    if !output.windows(5).any(|bytes| bytes == b"37 93") {
        return Err("terminal resize not applied inside guest".into());
    }
    apply(
        &handle,
        &context,
        ControlCommand::Input {
            bytes: b"sleep 30\n".to_vec(),
        },
    )?;
    std::thread::sleep(Duration::from_millis(250));
    apply(&handle, &context, ControlCommand::Interrupt)?;
    apply(
        &handle,
        &context,
        ControlCommand::Input {
            bytes: b"printf '\\nFOREGROUND_INTERRUPTED\\n'\n".to_vec(),
        },
    )?;
    wait_output(&handle, b"FOREGROUND_INTERRUPTED\r", Duration::from_secs(3))?;
    apply(&handle, &context, ControlCommand::Input {
        bytes: b"fixture_index=0; while test $fixture_index -lt 10000; do printf '01234567890123456789012345678901234567890123456789012345678901234567890123456789\\n'; fixture_index=$((fixture_index+1)); done; printf '\\nFLOOD_FINISHED\\n'\n".to_vec(),
    })?;
    wait_output(&handle, b"FLOOD_FINISHED\r", Duration::from_secs(10))?;
    if !matches!(viewer.next(Duration::from_secs(1))?, Some(SessionEvent::Terminal(frame)) if frame.gap)
    {
        return Err("slow viewer lacked replay gap".into());
    }
    handle.grant(OWNER, "fixture-viewer", None)?;
    if viewer.next(Duration::ZERO).is_ok() {
        return Err("revoked viewer retained access".into());
    }
    if mode == "missing-cgroup" {
        recovery::remove_owned_cgroup(&context)?;
    }
    apply(&handle, &context, ControlCommand::Stop)?;
    let snapshot = handle.snapshot(OWNER)?;
    if snapshot.phase != RuntimePhase::Stopped {
        return Err("stop acknowledged before cleanup".into());
    }
    handle.stop(OWNER)?;
    if mode == "missing-cgroup" {
        recovery::verify()?;
    }
    if fs::read_dir(root.join("node/records"))?.next().is_some() {
        return Err("node resources retained after applied stop".into());
    }
    if let Some(checkpoint) = snapshot.checkpoint {
        node.checkpoints().destroy(&checkpoint, &context)?;
    }
    println!(
        "managed_session_fixture=passed scope=development guest_build=true shell=true resize=true interrupt=true replay=true viewer_revocation=true vm_destroyed=true"
    );
    Ok(())
}

fn apply(handle: &SessionHandle, context: &SessionContext, command: ControlCommand) -> Result<()> {
    // Stop includes encrypted disk retention and fsync. This development bound
    // does not change the service's bounded freeze or VM termination deadline.
    let acknowledgement_timeout = if matches!(command, ControlCommand::Stop) {
        Duration::from_secs(120)
    } else {
        Duration::from_secs(8)
    };
    let controller = handle.acquire_control(OWNER, "fixture-client", &[], false)?;
    let request = ControlRequest {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-control".into(),
        context: context.clone(),
        request_id: format!("control-{}-{}", controller.epoch, controller.next_sequence),
        channel_id: "shell".into(),
        controller_id: "fixture-client".into(),
        control_lease_epoch: controller.epoch,
        control_sequence: controller.next_sequence,
        command,
    };
    let initial = handle.control(OWNER, request.clone())?;
    initial.validate_for(&request)?;
    let deadline = Instant::now() + acknowledgement_timeout;
    loop {
        let ack = handle.acknowledgement(OWNER, &request.request_id)?;
        ack.validate_for(&request)?;
        match ack.state {
            ControlState::Applied | ControlState::Interrupted => return Ok(()),
            ControlState::Rejected => {
                return Err(format!("control rejected: {}", ack.reason).into());
            }
            ControlState::Accepted => (),
        }
        if Instant::now() > deadline {
            return Err("control acknowledgement timeout".into());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn wait_output(handle: &SessionHandle, marker: &[u8], timeout: Duration) -> Result<Vec<u8>> {
    let deadline = Instant::now() + timeout;
    let mut cursor = 0;
    let mut output = Vec::new();
    loop {
        for frame in handle.replay(OWNER, "shell", cursor, 128)? {
            if frame.gap {
                return Err("fixture output truncated".into());
            }
            cursor = frame.sequence;
            output.extend(frame.bytes);
        }
        if output.windows(marker.len()).any(|bytes| bytes == marker) {
            return Ok(output);
        }
        if Instant::now() > deadline {
            // Only the registered model-free fixture runs here; no credentials
            // or provider profile is admitted by this development driver.
            let tail = &output[output.len().saturating_sub(2048)..];
            return Err(format!(
                "guest output timeout marker={} fixture_tail={}",
                String::from_utf8_lossy(marker),
                String::from_utf8_lossy(tail)
            )
            .into());
        }
        if !matches!(
            handle.snapshot(OWNER)?.phase,
            RuntimePhase::Running | RuntimePhase::RebaseRequired
        ) {
            return Err("session failed awaiting output".into());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn fixture_lease(manifest: RuntimeManifest) -> Result<SessionLease> {
    let now = u64::try_from(now_ms())?;
    let mut lease = SessionLease {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-lease".into(),
        purpose: ManagedPurpose::ManagedAgent,
        context: SessionContext {
            session_id: "fixture-session-service".into(),
            generation: 1,
            run_id: "fixture-run-service".into(),
            owner_id: OWNER.into(),
            repository: "fixture/repo".into(),
            source_revision: "a".repeat(40),
            runner_id: "fixture-node".into(),
            runner_epoch: 1,
            lease_id: "fixture-lease-service".into(),
            lease_epoch: 1,
            job_digest: manifest.recipe_digest.clone(),
            environment_digest: manifest.environment_digest.clone(),
            runtime_digest: runtime_digest(&manifest)?,
            policy_revision: manifest.policy_revision.clone(),
        },
        profile_id: "fixture".into(),
        workspace: WorkspaceSource::EmptyFixture,
        checkpoint: None,
        connection_bindings: vec![],
        signature: "0".repeat(128),
        runtime: manifest,
        resources: SessionResources {
            vcpus: 1,
            memory_mib: 256,
            workspace_gib: 1,
            pids_max: 128,
            runtime_seconds: 120,
            idle_seconds: 60,
            ..SessionResources::default()
        },
        issued_at_unix_millis: now,
        expires_at_unix_millis: now + 120000,
    };
    lease.context.job_digest = lease.job_digest()?;
    Ok(lease)
}
