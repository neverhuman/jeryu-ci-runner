//! Only a valid bounded root-owned journal authorizes deleting its fixed UUID
//! data file. Unknown or corrupt entries block admission without broad cleanup.
use super::*;
use std::io::Read;
use std::os::unix::fs::MetadataExt;

fn valid_id(id: &str) -> bool {
    id.len() == 32
        && id
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
pub(super) fn create(root: &Path, id: &str, upload: &BundleUpload) -> RunnerResult<File> {
    if !valid_id(id) {
        return Err(failed("bundle_staging_id_invalid"));
    }
    let mut journal = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(nix::libc::O_NOFOLLOW)
        .open(root.join(format!("{id}.json")))?;
    let bytes = upload
        .to_json()
        .map_err(|_| failed("bundle_upload_invalid"))?;
    if bytes.len() > 16 * 1024 {
        return Err(failed("bundle_metadata_limit"));
    }
    journal.write_all(&bytes)?;
    journal.sync_all()?;
    File::open(root)?.sync_all()?;
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(nix::libc::O_NOFOLLOW)
        .open(root.join(format!("{id}.bin")))?;
    File::open(root)?.sync_all()?;
    Ok(file)
}
fn read(root: &Path, id: &str) -> RunnerResult<()> {
    if !valid_id(id) {
        return Err(failed("bundle_staging_id_invalid"));
    }
    let file = custody::private_file(&root.join(format!("{id}.json")), false)?;
    if file.metadata()?.len() > 16 * 1024 {
        return Err(failed("bundle_metadata_limit"));
    }
    let mut bytes = Vec::new();
    file.take(16 * 1024 + 1).read_to_end(&mut bytes)?;
    BundleUpload::from_json(&bytes).map_err(|_| failed("bundle_staging_record_invalid"))?;
    Ok(())
}
pub(super) fn discard(root: &Path, id: &str) -> RunnerResult<()> {
    read(root, id)?;
    let data = root.join(format!("{id}.bin"));
    match std::fs::symlink_metadata(&data) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
        Err(error) => return Err(error.into()),
        Ok(meta) => {
            if !meta.is_file()
                || meta.uid() != 0
                || meta.nlink() != 1
                || ![0o600, 0o444].contains(&(meta.mode() & 0o777))
            {
                return Err(failed("bundle_staging_custody_denied"));
            }
            std::fs::remove_file(&data)?;
        }
    }
    // Persist data deletion before the journal ceases to authorize it.
    File::open(root)?.sync_all()?;
    std::fs::remove_file(root.join(format!("{id}.json")))?;
    File::open(root)?.sync_all()?;
    Ok(())
}
pub(super) fn reconcile(root: &Path) -> RunnerResult<bool> {
    let mut clean = true;
    for (count, entry) in std::fs::read_dir(root)?.enumerate() {
        if count >= 8193 {
            return Err(failed("bundle_staging_inventory_limit"));
        }
        let entry = entry?;
        let name = entry.file_name();
        let Some(id) = name.to_str().and_then(|name| name.strip_suffix(".json")) else {
            continue;
        };
        if !valid_id(id) || discard(root, id).is_err() {
            clean = false;
        }
    }
    // This second bounded pass catches unknown entries and orphan data. A
    // corrupt record does not prevent cleanup of later valid owned records.
    for (count, entry) in std::fs::read_dir(root)?.enumerate() {
        if count >= 8193 {
            return Err(failed("bundle_staging_inventory_limit"));
        }
        if entry?.file_name() != "registry.lock" {
            clean = false;
        }
    }
    Ok(clean)
}
