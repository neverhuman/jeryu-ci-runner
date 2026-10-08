//! One damaged record cannot stop reconciliation of unrelated owned resources.
use super::*;
use std::io::Read;

pub(super) fn load(root: &Path) -> RunnerResult<Vec<ResourceRecord>> {
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
            .and_then(|id| read(&entry.path(), id));
        match record {
            Ok(record) => records.push(record),
            Err(_) => quarantine(root, &entry.path())?,
        }
    }
    Ok(records)
}

fn read(path: &Path, id: &str) -> RunnerResult<ResourceRecord> {
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
    decode(&bytes, id)
}

fn decode(bytes: &[u8], id: &str) -> RunnerResult<ResourceRecord> {
    if bytes.len() > 16 * 1024 {
        return Err(failed("node_journal_invalid"));
    }
    let record: ResourceRecord =
        serde_json::from_slice(bytes).map_err(|_| failed("node_journal_invalid"))?;
    if record.resource_id != id
        || !(200000..200064).contains(&record.uid)
        || record.memory_mib == 0
        || record.workspace_gib == 0
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
    #[test]
    fn invalid_records_and_oversize_fail_without_ever_becoming_cleanup_authority() {
        assert!(decode(b"{truncated", &"a".repeat(32)).is_err());
        assert!(decode(b"{\"resource_id\":\"../../\",\"uid\":0}", &"a".repeat(32)).is_err());
        assert!(decode(&vec![0; 16 * 1024 + 1], &"a".repeat(32)).is_err());
    }
}
