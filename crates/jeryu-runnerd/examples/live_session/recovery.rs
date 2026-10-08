//! Fault injection on a dedicated development node, confined to the fixture VM.
use super::*;
use jeryu_runner_microvm::journal::ResourceRecord;
const FAULT_CGROUP: &str = "/sys/fs/cgroup/jeryu-fixture-recovery";

pub fn remove_owned_cgroup(context: &SessionContext) -> Result<()> {
    let records: Vec<_> =
        fs::read_dir(Path::new(ROOT).join("node/records"))?.collect::<std::io::Result<_>>()?;
    if records.len() != 1 {
        return Err("recovery fixture requires one owned VM".into());
    }
    let record: ResourceRecord = serde_json::from_slice(&fs::read(records[0].path())?)?;
    if record.context != *context
        || record.resource_id.len() != 32
        || !record
            .resource_id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    {
        return Err("recovery fixture resource mismatch".into());
    }
    let cgroup = Path::new("/sys/fs/cgroup/jeryu-microvm").join(&record.resource_id);
    let pid = record.vmm.ok_or("missing owned process identity")?.host_pid;
    let fault = Path::new(FAULT_CGROUP);
    fs::create_dir(fault)?;
    for (name, limit) in [
        ("memory.max", "536870912"),
        ("pids.max", "128"),
        ("cpu.max", "100000 100000"),
    ] {
        fs::write(fault.join(name), limit)?;
    }
    fs::write(fault.join("cgroup.procs"), pid.to_string())?;
    fs::remove_dir(cgroup)?;
    Ok(())
}
pub fn verify() -> Result<()> {
    let fault = Path::new(FAULT_CGROUP);
    if !fs::read_to_string(fault.join("cgroup.events"))?
        .lines()
        .any(|line| line == "populated 0")
    {
        return Err("VM survived missing-cgroup cleanup".into());
    }
    fs::remove_dir(fault)?;
    println!("missing_cgroup_recovery=passed pidfd_kill=true vm_destroyed=true");
    Ok(())
}

/// Dedicated test-node cleanup after failed evidence, through fenced APIs.
pub fn discard_checkpoints(node: &jeryu_runner_microvm::supervisor::Node) -> Result<()> {
    use sha2::{Digest, Sha256};
    let root = Path::new(ROOT).join("node/checkpoints");
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let id = entry.file_name().to_string_lossy().into_owned();
        if id.len() != 32
            || !id
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            continue;
        }
        let bytes = fs::read(entry.path().join("manifest.json"))?;
        let manifest = CheckpointManifest::from_json(&bytes)?;
        if manifest.context.owner_id != OWNER || manifest.context.repository != "fixture/repo" {
            return Err("cleanup fixture owner mismatch".into());
        }
        let reference = CheckpointReference {
            checkpoint_id: id,
            manifest_digest: format!(
                "sha256:{}",
                Sha256::digest(&bytes)
                    .iter()
                    .map(|b| format!("{b:02x}"))
                    .collect::<String>()
            ),
        };
        node.checkpoints().destroy(&reference, &manifest.context)?;
    }
    println!("owned_fixture_checkpoints_discarded=true");
    Ok(())
}

/// A malformed unrelated record may not suppress expiry cleanup or allow reuse.
pub fn corrupt_record(
    service: &SessionService,
    node: &jeryu_runner_microvm::supervisor::Node,
    handle: &SessionHandle,
    context: &SessionContext,
) -> Result<()> {
    use std::{fs::OpenOptions, io::Write, os::unix::fs::OpenOptionsExt};
    let root = Path::new(ROOT).join("node");
    let records: Vec<_> = fs::read_dir(root.join("records"))?.collect::<std::io::Result<_>>()?;
    if records.len() != 1 {
        return Err("corrupt-record fixture requires one VM".into());
    }
    let mut record: ResourceRecord = serde_json::from_slice(&fs::read(records[0].path())?)?;
    if record.context != *context {
        return Err("corrupt-record fixture ownership mismatch".into());
    }
    let malformed = root.join("records/ffffffffffffffffffffffffffffffff.json");
    let marker = b"{development-owned-invalid-record";
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(malformed)?;
    file.write_all(marker)?;
    file.sync_all()?;
    // Trusted fault injector expires exactly its own VM, without guest authority.
    record.expires_at_unix_millis = u64::try_from(now_ms())?.saturating_sub(1);
    fs::write(records[0].path(), serde_json::to_vec(&record)?)?;
    node.reconcile()?;
    if fs::read_dir(root.join("records"))?.next().is_some() {
        return Err("damaged record suppressed valid VM cleanup".into());
    }
    let quarantine: Vec<_> =
        fs::read_dir(root.join("quarantine"))?.collect::<std::io::Result<_>>()?;
    if quarantine.len() != 1 || fs::read(quarantine[0].path())? != marker {
        return Err("damaged record was not preserved as opaque quarantine".into());
    }
    let mut next = fixture_lease(RuntimeManifest::from_json(&fs::read(
        Path::new(ROOT).join("runtime.json"),
    )?)?)?;
    next.context.session_id = "fixture-quarantine-admission".into();
    next.context.run_id = "fixture-quarantine-admission-run".into();
    next.context.lease_id = "fixture-quarantine-admission-lease".into();
    authority::sign(&mut next)?;
    match service.start(next) {
        Err(e) if e.code() == "node_journal_quarantined" => (),
        Err(e) => {
            return Err(format!(
                "admission rejected before quarantine check code={}",
                e.code()
            )
            .into());
        }
        Ok(admitted) => {
            admitted.stop(OWNER)?;
            return Err("unknown VM ownership allowed admission".into());
        }
    }
    handle.stop(OWNER)?;
    if let Some(reference) = handle.snapshot(OWNER)?.checkpoint {
        node.checkpoints().destroy(&reference, context)?;
    }
    // Only the exact marker created above is removed after every assertion passed.
    fs::remove_file(quarantine[0].path())?;
    println!(
        "corrupt_record_recovery=passed unrelated_vm_destroyed=true quarantine_preserved=true admission_fenced=true owned_fault_removed=true"
    );
    Ok(())
}
