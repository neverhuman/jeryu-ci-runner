//! Full logical resources stay reserved until owned cleanup, even for sparse
//! disks or sessions already stopping. Missing historic CPU charges are maximal.
use super::*;

pub(super) fn check(
    config: &NodeConfig,
    existing: &[ResourceRecord],
    lease: &SessionLease,
    retained_bytes: u64,
    artifact_bytes: u64,
) -> RunnerResult<()> {
    let memory = existing
        .iter()
        .map(|r| u64::from(r.memory_mib) + 256)
        .sum::<u64>()
        + u64::from(lease.resources.memory_mib)
        + 256;
    // Reserve a second full disk for peak authenticated retention before the
    // original can be destroyed. Images/source copies also consume host space.
    let disk = existing.iter().try_fold(0u128, |sum, record| {
        Ok::<_, RunnerError>(sum + disk_charge(record)?)
    })? + new_disk_charge(lease, artifact_bytes)?
        + u128::from(retained_bytes);
    let cpu =
        existing.iter().map(|r| u64::from(r.vcpus)).sum::<u64>() + u64::from(lease.resources.vcpus);
    if existing.len() >= config.capacity
        || memory > u64::from(config.memory_budget_mib)
        || disk > u128::from(config.disk_budget_gib) * (1 << 30)
        || cpu > u64::from(config.cpu_budget_vcpus)
    {
        return Err(failed("microvm_capacity_unavailable"));
    }
    Ok(())
}

fn disk_charge(record: &ResourceRecord) -> RunnerResult<u128> {
    let bytes = u64::from(record.workspace_gib) * (1 << 30);
    Ok(u128::from(bytes)
        + u128::from(crate::checkpoint::storage_charge(bytes)?)
        + u128::from(record.artifact_bytes))
}
pub(super) fn new_disk_charge(lease: &SessionLease, artifact_bytes: u64) -> RunnerResult<u128> {
    let bytes = u64::from(lease.resources.workspace_gib) * (1 << 30);
    Ok(u128::from(bytes)
        + u128::from(crate::checkpoint::storage_charge(bytes)?)
        + u128::from(artifact_bytes))
}

pub(super) fn artifact_bytes(runtime: &VerifiedRuntime, lease: &SessionLease) -> RunnerResult<u64> {
    let source = runtime.workspace_bundle(&lease.workspace)?;
    let bytes = runtime
        .boot_artifact_bytes()?
        .checked_add(source.as_ref().map_or(0, |artifact| artifact.len()))
        .ok_or_else(|| failed("microvm_artifact_capacity_invalid"))?;
    if bytes > 64 * (1 << 30) {
        return Err(failed("microvm_artifact_capacity_invalid"));
    }
    Ok(bytes)
}

pub(super) fn check_free_space(
    journal: &NodeJournal,
    state_dir: &std::path::Path,
    existing: &[ResourceRecord],
    additional: u128,
) -> RunnerResult<()> {
    use std::os::unix::fs::MetadataExt;
    let mut needed = additional;
    for record in existing {
        let root = journal.jail_root(&record.resource_id)?;
        let mut allocated = 0u128;
        // Metadata only, for fixed owned host files. Never mount a guest disk.
        for role in [
            "workspace",
            "kernel",
            "rootfs",
            "firecracker",
            "source-bundle",
        ] {
            let meta = match std::fs::symlink_metadata(root.join(role)) {
                Ok(meta) => meta,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e.into()),
            };
            if !meta.is_file() || meta.nlink() != 1 || ![0, record.uid].contains(&meta.uid()) {
                return Err(failed("microvm_resource_custody_failed"));
            }
            allocated += u128::from(meta.blocks()) * 512;
        }
        needed += disk_charge(record)?.saturating_sub(allocated);
    }
    let filesystem = nix::sys::statvfs::statvfs(state_dir)
        .map_err(|_| failed("microvm_disk_capacity_unavailable"))?;
    let available =
        u128::from(filesystem.blocks_available()) * u128::from(filesystem.fragment_size());
    if needed > available {
        return Err(failed("microvm_disk_capacity_unavailable"));
    }
    Ok(())
}
