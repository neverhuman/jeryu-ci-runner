use super::*;
use std::os::unix::fs::{DirBuilderExt, MetadataExt};

pub(super) fn private_directory(path: &Path) -> RunnerResult<()> {
    trusted_directory(
        path.parent()
            .ok_or_else(|| failed("bundle_registry_custody_denied"))?,
    )?;
    match std::fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => File::open(
            path.parent()
                .ok_or_else(|| failed("bundle_registry_custody_denied"))?,
        )?
        .sync_all()?,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => (),
        Err(error) => return Err(error.into()),
    }
    trusted_directory(path)?;
    if std::fs::metadata(path)?.mode() & 0o077 != 0 {
        return Err(failed("bundle_registry_custody_denied"));
    }
    Ok(())
}
pub(super) fn private_file(path: &Path, create: bool) -> RunnerResult<File> {
    trusted_directory(
        path.parent()
            .ok_or_else(|| failed("bundle_registry_custody_denied"))?,
    )?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(create)
        .truncate(false)
        .mode(0o600)
        .custom_flags(nix::libc::O_NOFOLLOW)
        .open(path)?;
    private_metadata(&file.metadata()?)?;
    Ok(file)
}
pub(super) fn private_metadata(meta: &std::fs::Metadata) -> RunnerResult<()> {
    if !meta.is_file() || meta.uid() != 0 || meta.nlink() != 1 || meta.mode() & 0o077 != 0 {
        return Err(failed("bundle_registry_custody_denied"));
    }
    Ok(())
}
pub(super) fn source_name(name: &str) -> bool {
    name.len() == 64
        && name
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
pub(super) fn inventory(root: &Path) -> RunnerResult<(u64, usize)> {
    let mut bytes = 0u64;
    let mut objects = 0;
    for (count, entry) in std::fs::read_dir(root)?.enumerate() {
        if count >= 65536 {
            return Err(failed("bundle_registry_inventory_limit"));
        }
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            return Err(failed("bundle_registry_custody_denied"));
        };
        if name == ".source-staging" {
            continue;
        }
        if !source_name(name) {
            return Err(failed("bundle_registry_custody_denied"));
        }
        trusted_directory(&entry.path())?;
        let path = entry.path().join("source-bundle");
        match std::fs::symlink_metadata(&path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
            Ok(_) => (),
        }
        let file = crate::artifacts::trusted_file(&path, false)?;
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
