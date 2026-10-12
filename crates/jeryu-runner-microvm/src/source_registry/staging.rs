//! Only a valid bounded root-owned journal authorizes deleting its fixed UUID
//! data file. Unknown or corrupt entries block admission without broad cleanup.
use super::*;
use std::io::Read;
use std::os::unix::fs::MetadataExt;

const METADATA_LIMIT: u64 = 16 * 1024;

fn valid_id(id: &str) -> bool {
    id.len() == 32
        && id
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
pub(super) fn create(root: &Directory, id: &str, upload: &BundleUpload) -> RunnerResult<File> {
    if !valid_id(id) {
        return Err(failed("bundle_staging_id_invalid"));
    }
    let bytes = upload
        .to_json()
        .map_err(|_| failed("bundle_upload_invalid"))?;
    if bytes.len() as u64 > METADATA_LIMIT {
        return Err(failed("bundle_metadata_limit"));
    }
    let mut journal = root.create_private(Path::new(&format!("{id}.json")))?;
    journal.write_all(&bytes)?;
    journal.sync_all()?;
    root.sync()?;
    match root.create_private(Path::new(&format!("{id}.bin"))) {
        Ok(file) => Ok(file),
        Err(error) => {
            // A failed exclusive create does not authorize deleting its
            // existing leaf. Withdraw only our held journal's authority.
            root.remove_file(Path::new(&format!("{id}.json")), &journal)?;
            root.sync()?;
            Err(error)
        }
    }
}
fn read(root: &Directory, id: &str) -> RunnerResult<File> {
    if !valid_id(id) {
        return Err(failed("bundle_staging_id_invalid"));
    }
    let mut file = root
        .open_file(
            Path::new(&format!("{id}.json")),
            FileRole::Configuration { private: true },
            u64::MAX,
        )
        .map_err(|_| failed("bundle_staging_custody_denied"))?;
    if file.metadata()?.len() > METADATA_LIMIT {
        return Err(failed("bundle_metadata_limit"));
    }
    let mut bytes = Vec::new();
    (&mut file)
        .take(METADATA_LIMIT + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > METADATA_LIMIT {
        return Err(failed("bundle_metadata_limit"));
    }
    BundleUpload::from_json(&bytes).map_err(|_| failed("bundle_staging_record_invalid"))?;
    Ok(file)
}
pub(super) fn discard(
    root: &Directory,
    id: &str,
    expected: Option<&File>,
    promoted: bool,
) -> RunnerResult<()> {
    let journal = read(root, id)?;
    let data = format!("{id}.bin");
    let data = Path::new(&data);
    if root.entry_exists(data)? {
        let file = root
            .open_file(data, FileRole::Configuration { private: false }, 1 << 30)
            .map_err(|_| failed("bundle_staging_custody_denied"))?;
        if ![0o600, 0o444].contains(&(file.metadata()?.mode() & 0o777)) {
            return Err(failed("bundle_staging_custody_denied"));
        }
        if let Some(expected) = expected {
            root.require_file_identity(data, expected)
                .map_err(|_| failed("bundle_staging_custody_denied"))?;
        }
        root.remove_file(data, &file)
            .map_err(|_| failed("bundle_staging_custody_denied"))?;
    } else if let Some(expected) = expected {
        // Missing staging data is expected after our promotion or unlink.
        // An active file moved elsewhere still has a link: preserve its
        // journal and charge instead of calling that ambiguous move cleanup.
        if !promoted && expected.metadata()?.nlink() != 0 {
            return Err(failed("bundle_staging_custody_denied"));
        }
    }
    // Persist data deletion before the held journal ceases to authorize it.
    root.sync()?;
    root.remove_file(Path::new(&format!("{id}.json")), &journal)
        .map_err(|_| failed("bundle_staging_custody_denied"))?;
    root.sync()
}
pub(super) fn reconcile(root: &Directory) -> RunnerResult<bool> {
    let mut clean = true;
    for name in root
        .entries_bounded(8193)
        .map_err(|_| failed("bundle_staging_inventory_limit"))?
    {
        let Some(id) = name.to_str().and_then(|name| name.strip_suffix(".json")) else {
            continue;
        };
        if !valid_id(id) || discard(root, id, None, false).is_err() {
            clean = false;
        }
    }
    // This second bounded pass catches unknown entries and orphan data. A
    // corrupt record does not prevent cleanup of later valid owned records.
    for name in root
        .entries_bounded(8193)
        .map_err(|_| failed("bundle_staging_inventory_limit"))?
    {
        if name != Path::new("registry.lock") {
            clean = false;
        }
    }
    Ok(clean)
}
