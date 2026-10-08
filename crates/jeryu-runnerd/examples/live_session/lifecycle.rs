//! Automatic and direct stop must retain a proved flush and resume in a new VM.
use super::*;
use jeryu_runner_microvm::{journal::ResourceRecord, supervisor::Node};

pub fn run(
    service: &SessionService,
    node: &Node,
    mut lease: SessionLease,
    mode: &str,
) -> Result<()> {
    lease.resources.runtime_seconds = if mode == "runtime-stop" { 12 } else { 120 };
    lease.resources.idle_seconds = if mode == "idle-stop" {
        4
    } else {
        lease.resources.runtime_seconds.min(60)
    };
    lease.issued_at_unix_millis = u64::try_from(now_ms())?;
    lease.expires_at_unix_millis =
        lease.issued_at_unix_millis + u64::from(lease.resources.runtime_seconds) * 1000;
    lease.context.job_digest = lease.job_digest()?;
    authority::sign(&mut lease)?;
    let first_context = lease.context.clone();
    let first = DispatchEngine::new().dispatch_managed_session(service, lease.clone())?;
    apply(&first, &first_context, ControlCommand::Input { bytes: b"printf 'AUTO_RETAINED' > auto-retained.txt; printf 'TMPFS_ONLY' > /run/agent-home/auto-runtime; printf '\\nAUTOMATIC_WORK_CREATED\\n'\n".to_vec() })?;
    wait_output(&first, b"AUTOMATIC_WORK_CREATED\r", Duration::from_secs(5))?;
    let record = owned_record(&first_context)?;
    let observing = Instant::now();
    let execution_deadline = if mode == "runtime-stop" {
        lease.expires_at_unix_millis
    } else {
        u64::try_from(now_ms())? + if mode == "idle-stop" { 8000 } else { 5000 }
    };
    if mode == "direct-stop" {
        first.stop(OWNER)?;
    }
    // Retention may fsync a full encrypted disk on a busy development host.
    // Independently verify VM death; this does not extend execution authority.
    let deadline = Instant::now() + Duration::from_secs(120);
    let mut dead_after = None;
    let snapshot = loop {
        if vm_dead(&record)? && dead_after.is_none() {
            dead_after = Some(observing.elapsed());
        }
        if u64::try_from(now_ms())? > execution_deadline && dead_after.is_none() {
            return Err("VM survived the execution cutoff during retention".into());
        }
        let snapshot = first.snapshot(OWNER)?;
        if snapshot.phase == RuntimePhase::Stopped {
            break snapshot;
        }
        if snapshot.phase == RuntimePhase::Failed || Instant::now() > deadline {
            return Err(format!(
                "automatic stop failed phase={:?} reason={:?} vm_dead={}",
                snapshot.phase,
                snapshot.reason,
                dead_after.is_some()
            )
            .into());
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let dead_after = dead_after.ok_or("stop finished before verified VM death")?;
    println!(
        "lifecycle_timing mode={mode} vm_dead_millis={} retained_millis={}",
        dead_after.as_millis(),
        observing.elapsed().as_millis()
    );
    let expected_reason = match mode {
        "idle-stop" => Some("idle_timeout"),
        "runtime-stop" => Some("runtime_limit"),
        _ => None,
    };
    if snapshot.reason.as_deref() != expected_reason {
        return Err("lifecycle stop reported the wrong reason".into());
    }
    let checkpoint = snapshot.checkpoint.ok_or("automatic checkpoint absent")?;
    let manifest = node.checkpoints().manifest(&checkpoint)?;
    if !manifest.filesystem_flushed {
        return Err("automatic stop did not prove a flushed filesystem".into());
    }
    if fs::read_dir(Path::new(ROOT).join("node/records"))?
        .next()
        .is_some()
    {
        return Err("automatic stop kept a VM record".into());
    }
    lease.context.generation += 1;
    lease.context.run_id = "automatic-resume-run".into();
    lease.context.lease_id = "automatic-resume-lease".into();
    lease.context.lease_epoch += 1;
    lease.resources.runtime_seconds = 120;
    lease.resources.idle_seconds = 60;
    lease.checkpoint = Some(checkpoint.clone());
    source::configure(&mut lease, "resume-main")?;
    lease.context.source_revision = manifest
        .workspace
        .as_ref()
        .ok_or("checkpoint has no source receipt")?
        .head_revision
        .clone();
    lease.issued_at_unix_millis = u64::try_from(now_ms())?;
    lease.expires_at_unix_millis = lease.issued_at_unix_millis + 120000;
    lease.context.job_digest = lease.job_digest()?;
    authority::sign(&mut lease)?;
    let next_context = lease.context.clone();
    let next = DispatchEngine::new().dispatch_managed_session(service, lease)?;
    apply(&next, &next_context, ControlCommand::Input { bytes: b"test \"$(cat auto-retained.txt)\" = AUTO_RETAINED && test ! -e /run/agent-home/auto-runtime && test -f next-main.txt && git merge-base --is-ancestor refs/jeryu/main HEAD && printf '\\nAUTOMATIC_RESUME_VERIFIED\\n'\n".to_vec() })?;
    wait_output(
        &next,
        b"AUTOMATIC_RESUME_VERIFIED\r",
        Duration::from_secs(5),
    )?;
    apply(&next, &next_context, ControlCommand::Stop)?;
    let successor = next
        .snapshot(OWNER)?
        .checkpoint
        .ok_or("automatic successor checkpoint absent")?;
    if !node.checkpoints().manifest(&successor)?.filesystem_flushed
        || node.checkpoints().manifest(&checkpoint)? != manifest
    {
        return Err("successor flush or predecessor immutability failed".into());
    }
    node.checkpoints().destroy(&checkpoint, &first_context)?;
    node.checkpoints().destroy(&successor, &next_context)?;
    println!(
        "lifecycle_checkpoint=passed scope=development mode={mode} real_vms=2 filesystem_flushed=true user_work_resumed=true newer_main=true fresh_tmpfs=true predecessor_immutable=true vm_destroyed=true execution_cutoff_verified=true"
    );
    Ok(())
}

fn owned_record(context: &SessionContext) -> Result<ResourceRecord> {
    let records =
        fs::read_dir(Path::new(ROOT).join("node/records"))?.collect::<std::io::Result<Vec<_>>>()?;
    if records.len() != 1 {
        return Err("lifecycle fixture requires one owned VM".into());
    }
    let record: ResourceRecord = serde_json::from_slice(&fs::read(records[0].path())?)?;
    if record.context != *context
        || record.resource_id.len() != 32
        || !record.resource_id.bytes().all(|b| b.is_ascii_hexdigit())
        || record.vmm.is_none()
    {
        return Err("lifecycle fixture process ownership mismatch".into());
    }
    Ok(record)
}

/// Read-only observation of the previously bound process identity and cgroup.
/// This fixture never signals a PID or derives deletion authority from it.
fn vm_dead(record: &ResourceRecord) -> Result<bool> {
    let identity = record.vmm.as_ref().ok_or("missing VMM identity")?;
    let process = Path::new("/proc").join(identity.host_pid.to_string());
    let alive = match fs::read_to_string(process.join("stat")) {
        Ok(stat) => {
            let fields: Vec<_> = stat
                .rsplit_once(") ")
                .ok_or("invalid process state")?
                .1
                .split_whitespace()
                .collect();
            !matches!(fields.first(), Some(&"Z" | &"X"))
                && fields.get(19).and_then(|ticks| ticks.parse::<u64>().ok())
                    == Some(identity.start_ticks)
                && fs::read_to_string("/proc/sys/kernel/random/boot_id")?.trim() == identity.boot_id
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
        Err(e) => return Err(e.into()),
    };
    let events = Path::new("/sys/fs/cgroup/jeryu-microvm")
        .join(&record.resource_id)
        .join("cgroup.events");
    let empty = match fs::read_to_string(events) {
        Ok(events) => events.lines().any(|line| line == "populated 0"),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => true,
        Err(e) => return Err(e.into()),
    };
    Ok(!alive && empty)
}
