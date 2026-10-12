use super::*;
pub(super) fn directory(path: &Path) -> RunnerResult<Directory> {
    Directory::open(path).map_err(|_| failed("bundle_registry_custody_denied"))
}

pub(super) fn staging_directory(root: &Directory) -> RunnerResult<Directory> {
    let directory = root
        .child_directory(Path::new(".source-staging"))
        .map_err(|_| failed("bundle_registry_custody_denied"))?;
    if directory.mode()? != 0o700 {
        return Err(failed("bundle_registry_custody_denied"));
    }
    Ok(directory)
}
pub(super) fn source_name(name: &str) -> bool {
    name.len() == 64
        && name
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
pub(super) fn inventory(root: &Directory) -> RunnerResult<(u64, usize)> {
    let mut bytes = 0u64;
    let mut objects = 0;
    for entry in root
        .entries_bounded(65536)
        .map_err(|_| failed("bundle_registry_inventory_limit"))?
    {
        let Some(name) = entry.to_str() else {
            return Err(failed("bundle_registry_custody_denied"));
        };
        if name == ".source-staging" {
            continue;
        }
        if !source_name(name) {
            return Err(failed("bundle_registry_custody_denied"));
        }
        let directory = root
            .open_directory(&entry)
            .map_err(|_| failed("bundle_registry_custody_denied"))?;
        let name = Path::new("source-bundle");
        if !directory.entry_exists(name)? {
            continue;
        }
        let file = directory
            .open_file(name, FileRole::Immutable { executable: false }, u64::MAX)
            .map_err(|_| failed("bundle_registry_custody_denied"))?;
        let size = file.metadata()?.len();
        if !(512..=(1 << 30)).contains(&size) || size % 512 != 0 {
            return Err(failed("bundle_registry_size_invalid"));
        }
        bytes = bytes
            .checked_add(size + METADATA_CHARGE)
            .ok_or_else(|| failed("bundle_registry_size_invalid"))?;
        objects += 1;
        if objects > OBJECT_LIMIT {
            return Err(failed("bundle_registry_inventory_limit"));
        }
    }
    Ok((bytes, objects))
}
