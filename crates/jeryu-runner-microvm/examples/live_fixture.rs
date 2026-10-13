//! Dedicated local qualification fixture. Its test key is separate from release
//! authority and its evidence cannot qualify providers or a production release.
#[path = "live_fixture/descendants.rs"]
mod descendants;
use ed25519_dalek::{Signer, SigningKey};
use jeryu_runner_core::receipt::now_ms;
use jeryu_runner_microvm::{MicroVmSession, NodeConfig, artifacts::VerifiedRuntime};
use jeryu_runner_protocol::{
    guest::{GuestEvent, GuestProfile, GuestRequest},
    wire::v2::*,
};
use std::{
    fs,
    path::Path,
    time::{Duration, Instant},
};

const ROOT: &str = "/var/lib/jeryu-live-fixture";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = Path::new(ROOT);
    let manifest = RuntimeManifest::from_json(&fs::read(root.join("runtime.json"))?)?;
    let signature: [u8; 64] = fs::read(root.join("runtime.sig"))?
        .try_into()
        .map_err(|_| "signature length")?;
    let key: [u8; 32] = fs::read(root.join("fixture.pub"))?
        .try_into()
        .map_err(|_| "key length")?;
    let release_key = fs::read(root.join("release-authority.pub"))?
        .try_into()
        .map_err(|_| "release authority length")?;
    let runtime = VerifiedRuntime::admit_test(
        manifest.clone(),
        &signature,
        &release_key,
        &key,
        &root.join("artifacts"),
    )?;
    let now = u64::try_from(now_ms())?;
    let descendants = std::env::args().nth(1).as_deref() == Some("descendants");
    let mut lease = SessionLease {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-lease".into(),
        purpose: ManagedPurpose::ManagedAgent,
        context: SessionContext {
            session_id: "fixture-session".into(),
            generation: 1,
            run_id: "fixture-run".into(),
            owner_id: "user/fixture-owner".into(),
            repository: "fixture/repo".into(),
            source_revision: "a".repeat(40),
            runner_id: "fixture-node".into(),
            runner_epoch: 1,
            lease_id: "fixture-lease".into(),
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
            output_bytes_per_second: if descendants { 1024 } else { 1024 * 1024 },
            ..SessionResources::default()
        },
        issued_at_unix_millis: now,
        expires_at_unix_millis: now + 120000,
    };
    lease.context.job_digest = lease.job_digest()?;
    let seed = fs::read(root.join("lease-authority.seed"))?
        .try_into()
        .map_err(|_| "fixture authority length")?;
    lease.signature = hex::encode(
        SigningKey::from_bytes(&seed)
            .sign(&lease.signing_bytes()?)
            .to_bytes(),
    );
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
        uid_base: jeryu_runner_microvm::journal::LEGACY_UID_BASE,
    }
    .open()?;
    let started = Instant::now();
    let mut session = MicroVmSession::start(node, &runtime, lease)?;
    println!("live_vm_handshake_ms={}", started.elapsed().as_millis());
    session.send(&GuestRequest::ControlFence {
        request_id: "fixture-fence".into(),
        epoch: 1,
        ttl_millis: 30000,
        terminal_channels: vec![],
    })?;
    if descendants {
        return descendants::run(&mut session);
    }
    session.send(&GuestRequest::Start {
        channel: "shell".into(),
        profile: GuestProfile::Shell,
    })?;
    session.send(&GuestRequest::Resize {
        channel: "shell".into(),
        request_id: "resize-1".into(),
        control_epoch: 1,
        rows: 37,
        cols: 93,
    })?;
    session.send(&GuestRequest::Start {
        channel: "agent".into(),
        profile: GuestProfile::Fixture,
    })?;
    let mut built = false;
    let mut resized = false;
    while !built || !resized {
        match session.receive()? {
            GuestEvent::Exited { channel, exit_code } if channel == "agent" => {
                if exit_code != Some(0) {
                    return Err("guest fixture build failed".into());
                }
                built = true;
            }
            GuestEvent::Ack {
                request_id,
                applied,
                ..
            } if request_id == "resize-1" => {
                resized = applied;
            }
            GuestEvent::Output { channel, bytes, .. } => {
                print!("{channel}:{}", String::from_utf8_lossy(&bytes))
            }
            GuestEvent::Error { code } => return Err(code.into()),
            _ => (),
        }
    }
    session.send(&GuestRequest::Input { channel: "shell".into(), request_id: "input-1".into(), control_epoch: 1,
        bytes: b"test -f main.c && test -x build && test ! -e /var/lib/jeryu-live-fixture/host-only-sentinel && stty size && printf '\\nSHELL_VERIFIED\\n'\n".to_vec() })?;
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut shell = Vec::new();
    let mut applied = false;
    let marker = b"SHELL_VERIFIED\r";
    while !shell.windows(marker.len()).any(|v| v == marker) || !applied {
        if Instant::now() > deadline {
            return Err("guest shell control failed".into());
        }
        match session.receive()? {
            GuestEvent::Output { channel, bytes, .. } if channel == "shell" => shell.extend(bytes),
            GuestEvent::Ack {
                request_id,
                applied: ack,
                ..
            } if request_id == "input-1" => applied = ack,
            _ => (),
        }
    }
    if !shell.windows(5).any(|v| v == b"37 93") {
        return Err("guest resize was not applied".into());
    }
    session.stop()?;
    session.stop()?;
    if fs::read_dir(root.join("node/records"))?.next().is_some() {
        return Err("runtime resources retained".into());
    }
    println!(
        "live_kvm_fixture=passed scope=development vm_destroyed=true shell=true resize=true guest_build=true"
    );
    Ok(())
}
