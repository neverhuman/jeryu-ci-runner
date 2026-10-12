use super::*;

impl Directory {
    /// Existing entries, including incomplete prior attempts, are preserved.
    pub(crate) fn create_directory(&self, name: &Path) -> RunnerResult<Self> {
        leaf(name)?;
        mkdirat(&self.fd, name, Mode::from_raw_mode(0o700)).map_err(|_| denied())?;
        let directory = self.open_directory(name)?;
        fchmod(&directory.fd, Mode::from_raw_mode(0o700)).map_err(|_| denied())?;
        directory.sync()?;
        self.sync()?;
        Ok(directory)
    }

    pub(crate) fn require_directory_identity(
        &self,
        name: &Path,
        directory: &Self,
    ) -> RunnerResult<()> {
        leaf(name)?;
        let held = fstat(&directory.fd).map_err(|_| denied())?;
        let entry = statat(&self.fd, name, AtFlags::SYMLINK_NOFOLLOW).map_err(|_| denied())?;
        if held.st_mode & nix::libc::S_IFMT != nix::libc::S_IFDIR
            || (held.st_dev, held.st_ino) != (entry.st_dev, entry.st_ino)
        {
            return Err(denied());
        }
        Ok(())
    }

    pub(crate) fn promote_directory(
        &self,
        source: &Path,
        directory: &Self,
        target: &Path,
    ) -> RunnerResult<bool> {
        self.require_directory_identity(source, directory)?;
        leaf(target)?;
        match rustix::fs::renameat_with(
            &self.fd,
            source,
            &self.fd,
            target,
            rustix::fs::RenameFlags::NOREPLACE,
        ) {
            Ok(()) => Ok(true),
            Err(rustix::io::Errno::EXIST) => Ok(false),
            Err(_) => Err(denied()),
        }
    }

    /// Only the verified, empty directory can be removed. Never recurse.
    pub(crate) fn remove_directory(&self, name: &Path, directory: &Self) -> RunnerResult<()> {
        self.require_directory_identity(name, directory)?;
        rustix::fs::unlinkat(&self.fd, name, AtFlags::REMOVEDIR).map_err(|_| denied())
    }

    /// The journal supplies this exact resource UID after fencing all writers.
    /// The owned leaf is not returned as a root-owned Directory capability.
    pub(crate) fn open_workspace(&self, uid: u32, bytes: u64) -> RunnerResult<File> {
        let fd = openat(
            &self.fd,
            "root",
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(|_| denied())?;
        let meta = fstat(&fd).map_err(|_| denied())?;
        if uid == 0 || meta.st_uid != uid || meta.st_mode & 0o7777 != 0o700 {
            return Err(denied());
        }
        let fd = openat(
            &fd,
            "workspace",
            OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC | OFlags::NONBLOCK,
            Mode::empty(),
        )
        .map_err(|_| denied())?;
        let meta = fstat(&fd).map_err(|_| denied())?;
        if meta.st_uid != uid
            || meta.st_mode & nix::libc::S_IFMT != nix::libc::S_IFREG
            || meta.st_mode & 0o7777 != 0o600
            || meta.st_nlink != 1
            || meta.st_size < 0
            || meta.st_size as u64 != bytes
        {
            return Err(denied());
        }
        Ok(File::from(fd))
    }
}
