use super::{RunnerResult, denied};
use rustix::{
    fd::{AsFd, OwnedFd},
    fs::{AtFlags, Mode, OFlags, fchmod, fstat, fsync, mkdirat, openat, statat},
    io::Errno,
};
use std::{fs::File, io::Write};

fn directory_flags() -> OFlags {
    OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC
}

fn metadata_is_trusted(uid: u32, mode: u32) -> bool {
    uid == 0 && mode & nix::libc::S_IFMT == nix::libc::S_IFDIR && mode & 0o022 == 0
}

fn verify_directory(fd: &impl AsFd) -> RunnerResult<()> {
    let metadata = fstat(fd).map_err(|_| denied("image_staging_custody_denied"))?;
    if !metadata_is_trusted(metadata.st_uid, metadata.st_mode) {
        return Err(denied("image_staging_custody_denied"));
    }
    Ok(())
}

#[cfg(test)]
pub(super) fn trusted_root(path: &std::path::Path) -> RunnerResult<OwnedFd> {
    crate::custody::Directory::open(path)
        .map(crate::custody::Directory::into_fd)
        .map_err(|_| denied("image_staging_custody_denied"))
}

pub(super) fn directories(
    root: &impl AsFd,
    components: &[&str],
    create: bool,
) -> RunnerResult<Option<OwnedFd>> {
    let mut current = rustix::io::fcntl_dupfd_cloexec(root, 0)
        .map_err(|_| denied("image_staging_custody_denied"))?;
    for component in components {
        let mut created = false;
        let next = match openat(&current, *component, directory_flags(), Mode::empty()) {
            Ok(fd) => fd,
            Err(Errno::NOENT) if create => {
                mkdirat(&current, *component, Mode::from_raw_mode(0o755))
                    .map_err(|_| denied("image_staging_custody_denied"))?;
                created = true;
                openat(&current, *component, directory_flags(), Mode::empty())
                    .map_err(|_| denied("image_staging_custody_denied"))?
            }
            Err(Errno::NOENT) => return Ok(None),
            Err(_) => return Err(denied("image_staging_custody_denied")),
        };
        if created {
            // Force only our new directory's mode; never alter prior custody.
            fchmod(&next, Mode::from_raw_mode(0o755))
                .map_err(|_| denied("image_staging_custody_denied"))?;
            fsync(&current).map_err(|_| denied("image_staging_custody_denied"))?;
        }
        verify_directory(&next)?;
        current = next;
    }
    Ok(Some(current))
}

pub(super) fn entry_exists(directory: &impl AsFd, name: &str) -> RunnerResult<bool> {
    match statat(directory, name, AtFlags::SYMLINK_NOFOLLOW) {
        Ok(_) => Ok(true),
        Err(Errno::NOENT) => Ok(false),
        Err(_) => Err(denied("image_staging_custody_denied")),
    }
}

pub(super) fn write_fixed(
    directory: &impl AsFd,
    name: &str,
    bytes: &[u8],
    mode: u32,
) -> RunnerResult<()> {
    let fd = openat(
        directory,
        name,
        OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::from_raw_mode(mode),
    )
    .map_err(|_| denied("image_overlay_write_denied"))?;
    fchmod(&fd, Mode::from_raw_mode(mode)).map_err(|_| denied("image_overlay_write_denied"))?;
    let mut file = File::from(fd);
    file.write_all(bytes)
        .and_then(|()| file.sync_all())
        .map_err(|_| denied("image_overlay_write_denied"))?;
    fsync(directory).map_err(|_| denied("image_overlay_write_denied"))
}

#[cfg(test)]
pub(super) fn trusted_metadata_for_test(uid: u32, mode: u32) -> bool {
    metadata_is_trusted(uid, mode)
}
