//! Real resource admission through the same managed dispatch as product clients.
use super::*;
use std::os::unix::fs::MetadataExt;

pub fn deny_cpu(service: &SessionService, lease: &SessionLease) -> Result<()> {
    reject(service, lease, "cpu", 5, 1)?;
    // Eight logical GiB would fit 16 without the peak retention/image reserve.
    reject(service, lease, "disk", 1, 8)?;
    Ok(())
}
fn reject(
    service: &SessionService,
    lease: &SessionLease,
    name: &str,
    cpu: u8,
    disk: u32,
) -> Result<()> {
    let mut probe = lease.clone();
    probe.context.session_id = format!("{name}-probe-session");
    probe.context.run_id = format!("{name}-probe-run");
    probe.context.lease_id = format!("{name}-probe-lease");
    probe.resources.vcpus = cpu;
    probe.resources.workspace_gib = disk;
    probe.context.job_digest = probe.job_digest()?;
    authority::sign(&mut probe)?;
    match DispatchEngine::new().dispatch_managed_session(service, probe) {
        Err(error) if error.code() == "microvm_capacity_unavailable" => (),
        _ => return Err("signed resource overcommit was not rejected before allocation".into()),
    }
    if fs::read_dir(Path::new(ROOT).join("node/records"))?
        .next()
        .is_some()
    {
        return Err("capacity-denied request allocated resources".into());
    }
    Ok(())
}
pub fn verify_sparse(context: &SessionContext) -> Result<()> {
    let mut records = fs::read_dir(Path::new(ROOT).join("node/records"))?;
    let record: jeryu_runner_microvm::journal::ResourceRecord = serde_json::from_slice(&fs::read(
        records
            .next()
            .ok_or("missing sparse fixture record")??
            .path(),
    )?)?;
    if record.context != *context
        || record.vcpus != 1
        || record.artifact_bytes == 0
        || record.resource_id.len() != 32
        || !record
            .resource_id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        || records.next().is_some()
    {
        return Err("resource journal did not bind the allocated capacity".into());
    }
    let disk = fs::symlink_metadata(
        Path::new(ROOT)
            .join("node/j/firecracker")
            .join(&record.resource_id)
            .join("root/workspace"),
    )?;
    if !disk.is_file()
        || disk.uid() != record.uid
        || disk.len() != 1 << 30
        || disk.blocks() * 512 >= disk.len() / 2
    {
        return Err("fresh workspace is not a bounded sparse disk".into());
    }
    println!(
        "resource_admission=passed cpu_overcommit_denied_before_allocation=true sparse_logical_bytes={} allocated_bytes={} retention_peak_reserved=true",
        disk.len(),
        disk.blocks() * 512
    );
    Ok(())
}

pub fn verify_backpressure(handle: &SessionHandle, context: &SessionContext) -> Result<()> {
    use sha2::{Digest, Sha256};
    let bytes: Vec<u8> = (0..MAX_TERMINAL_BYTES).map(|i| (i % 256) as u8).collect();
    let hash: String = Sha256::digest(&bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let command = format!(
        "stty raw -echo; printf '\\nSLOW_INPUT_READY\\n'; sleep 2; /usr/bin/busybox dd bs=1 count={} of=slow-input.bin 2>/dev/null; stty sane; set -- $(/usr/bin/busybox sha256sum slow-input.bin); test \"$1\" = {hash} && printf '\\nREAL_PTY_BACKPRESSURE_VERIFIED\\n'\n",
        bytes.len()
    );
    apply(
        handle,
        context,
        ControlCommand::Input {
            bytes: command.into_bytes(),
        },
    )?;
    wait_output(handle, b"SLOW_INPUT_READY\n", Duration::from_secs(5))?;
    apply(handle, context, ControlCommand::Input { bytes })?;
    wait_output(
        handle,
        b"REAL_PTY_BACKPRESSURE_VERIFIED\r",
        Duration::from_secs(8),
    )?;
    println!(
        "real_pty_backpressure=passed delayed_read_seconds=2 input_bytes={} binary_sha256_matches=true",
        MAX_TERMINAL_BYTES
    );
    Ok(())
}
