//! One damaged record cannot stop reconciliation of unrelated owned resources.
use super::*;
use std::io::Read;

pub(super) fn load(root: &Path, uid_range: UidRange) -> RunnerResult<Vec<ResourceRecord>> {
    let mut records = vec![];
    for entry in std::fs::read_dir(root.join("records"))? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.ends_with(".new") && name.len() == 36 && valid_id(&name[..32]).is_ok() {
            continue;
        }
        let record = name
            .strip_suffix(".json")
            .filter(|id| valid_id(id).is_ok())
            .ok_or_else(|| failed("node_journal_invalid"))
            .and_then(|id| read(&entry.path(), id, uid_range));
        match record {
            Ok(record) => records.push(record),
            Err(_) => quarantine(root, &entry.path())?,
        }
    }
    Ok(records)
}

fn read(path: &Path, id: &str, uid_range: UidRange) -> RunnerResult<ResourceRecord> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_NOFOLLOW)
        .open(path)?;
    let meta = file.metadata()?;
    if !meta.is_file()
        || meta.uid() != 0
        || meta.mode() & 0o077 != 0
        || meta.nlink() != 1
        || meta.len() > 16 * 1024
    {
        return Err(failed("node_journal_invalid"));
    }
    let mut bytes = vec![];
    file.take(16 * 1024 + 1).read_to_end(&mut bytes)?;
    decode(&bytes, id, uid_range)
}

fn decode(bytes: &[u8], id: &str, uid_range: UidRange) -> RunnerResult<ResourceRecord> {
    if bytes.len() > 16 * 1024 {
        return Err(failed("node_journal_invalid"));
    }
    let record: ResourceRecord =
        serde_json::from_slice(bytes).map_err(|_| failed("node_journal_invalid"))?;
    if record.resource_id != id
        || !uid_range.contains(record.uid)
        || !(1..=32).contains(&record.vcpus)
        || record.artifact_bytes > 64 * (1 << 30)
        || !(128..=65536).contains(&record.memory_mib)
        || !(1..=512).contains(&record.workspace_gib)
        || record.context.validate().is_err()
        || record
            .firecracker_digest
            .strip_prefix("sha256:")
            .is_none_or(|digest| {
                digest.len() != 64
                    || !digest
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
    {
        return Err(failed("node_journal_invalid"));
    }
    Ok(record)
}

fn quarantine(root: &Path, entry: &Path) -> RunnerResult<()> {
    let directory = root.join("quarantine");
    std::fs::create_dir_all(&directory)?;
    trusted_directory(&directory)?;
    let destination = directory.join(uuid::Uuid::new_v4().simple().to_string());
    // rename moves the entry itself; a symlink is never followed or inspected.
    match std::fs::rename(entry, destination) {
        Ok(()) => {
            File::open(root.join("records"))?.sync_all()?;
            File::open(directory)?.sync_all()?;
            eprintln!("jeryu_microvm_reconciliation_failed code=node_journal_quarantined");
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
        Err(e) => return Err(e.into()),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(uid: u32) -> ResourceRecord {
        let digest = format!("sha256:{}", "a".repeat(64));
        ResourceRecord {
            resource_id: "a".repeat(32),
            uid,
            vcpus: 1,
            artifact_bytes: 1024,
            memory_mib: 256,
            workspace_gib: 1,
            context: SessionContext {
                session_id: "session".into(),
                generation: 1,
                run_id: "run".into(),
                owner_id: "user/owner".into(),
                repository: "fixture/repo".into(),
                source_revision: "a".repeat(40),
                runner_id: "node".into(),
                runner_epoch: 1,
                lease_id: "lease".into(),
                lease_epoch: 1,
                job_digest: digest.clone(),
                environment_digest: digest.clone(),
                runtime_digest: digest.clone(),
                policy_revision: digest.clone(),
            },
            expires_at_unix_millis: 1,
            state: ResourceState::Provisioning,
            firecracker_digest: digest,
            vmm: None,
            deadline: None,
            retain_workspace: false,
            workspace_flushed: false,
            checkpoint: None,
            workspace: None,
        }
    }

    #[test]
    fn records_are_cleanup_authority_only_in_the_exact_enrolled_block() {
        for base in [LEGACY_UID_BASE, 231104] {
            let range = UidRange::new(base).unwrap();
            for uid in [base, base + 63] {
                let record = record(uid);
                assert!(
                    decode(
                        &serde_json::to_vec(&record).unwrap(),
                        &record.resource_id,
                        range
                    )
                    .is_ok()
                );
            }
            for uid in [0, 1000, base - 1, base + 64, u32::MAX] {
                let record = record(uid);
                assert!(
                    decode(
                        &serde_json::to_vec(&record).unwrap(),
                        &record.resource_id,
                        range
                    )
                    .is_err()
                );
            }
        }
        let forged = record(LEGACY_UID_BASE);
        assert!(
            decode(
                &serde_json::to_vec(&forged).unwrap(),
                &forged.resource_id,
                UidRange::new(231104).unwrap()
            )
            .is_err()
        );
    }

    #[test]
    fn invalid_records_and_oversize_fail_without_ever_becoming_cleanup_authority() {
        let range = UidRange::new(LEGACY_UID_BASE).unwrap();
        assert!(decode(b"{truncated", &"a".repeat(32), range).is_err());
        assert!(
            decode(
                b"{\"resource_id\":\"../../\",\"uid\":0}",
                &"a".repeat(32),
                range
            )
            .is_err()
        );
        assert!(decode(&vec![0; 16 * 1024 + 1], &"a".repeat(32), range).is_err());
    }
}
