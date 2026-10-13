//! Root-owned filesystem capabilities. Checked paths are never reopened for use.
mod directories;
use jeryu_runner_core::{RunnerError, RunnerResult};
use rustix::{
    fd::OwnedFd,
    fs::{AtFlags, Mode, OFlags, fchmod, fstat, fsync, mkdirat, open, openat, statat},
};
use std::{
    fs::File,
    io::{Read, Write},
    os::unix::ffi::OsStrExt,
    path::{Component, Path, PathBuf},
};

/// Different roles retain their own permission requirements.
#[derive(Clone, Copy)]
pub enum FileRole {
    Immutable { executable: bool },
    Configuration { private: bool },
}

#[derive(Debug)]
pub struct Directory {
    fd: OwnedFd,
}

impl Directory {
    pub fn open(path: &Path) -> RunnerResult<Self> {
        if !path.is_absolute() {
            return Err(denied());
        }
        let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
        let mut fd = open("/", flags, Mode::empty()).map_err(|_| denied())?;
        verify_directory(&fd)?;
        for component in path.components() {
            match component {
                Component::RootDir => (),
                Component::Normal(name) => {
                    fd = openat(&fd, name, flags, Mode::empty()).map_err(|_| denied())?;
                    verify_directory(&fd)?;
                }
                _ => return Err(denied()),
            }
        }
        Ok(Self { fd })
    }

    pub(crate) fn into_fd(self) -> OwnedFd {
        self.fd
    }

    pub(crate) fn descend(&self, relative: &Path) -> RunnerResult<Self> {
        let fd = rustix::io::fcntl_dupfd_cloexec(&self.fd, 3).map_err(|_| denied())?;
        let mut current = Self { fd };
        for component in relative.components() {
            let Component::Normal(name) = component else {
                return Err(denied());
            };
            current = current.open_directory(Path::new(name))?;
        }
        Ok(current)
    }

    pub(crate) fn read_link(&self, name: &Path) -> RunnerResult<String> {
        leaf(name)?;
        let meta = statat(&self.fd, name, AtFlags::SYMLINK_NOFOLLOW).map_err(|_| denied())?;
        if meta.st_uid != 0
            || meta.st_nlink != 1
            || meta.st_mode & nix::libc::S_IFMT != nix::libc::S_IFLNK
        {
            return Err(denied());
        }
        let target = rustix::fs::readlinkat(&self.fd, name, Vec::new()).map_err(|_| denied())?;
        if target.to_bytes().len() > 4096 {
            return Err(denied());
        }
        String::from_utf8(target.to_bytes().to_vec()).map_err(|_| denied())
    }

    pub(crate) fn entry_type(&self, name: &Path) -> RunnerResult<rustix::fs::FileType> {
        leaf(name)?;
        let meta = statat(&self.fd, name, AtFlags::SYMLINK_NOFOLLOW).map_err(|_| denied())?;
        Ok(rustix::fs::FileType::from_raw_mode(meta.st_mode))
    }

    pub(crate) fn mode(&self) -> RunnerResult<u32> {
        Ok(fstat(&self.fd).map_err(|_| denied())?.st_mode & 0o777)
    }

    pub(crate) fn device(&self) -> RunnerResult<u64> {
        Ok(fstat(&self.fd).map_err(|_| denied())?.st_dev)
    }

    pub(crate) fn sync(&self) -> RunnerResult<()> {
        fsync(&self.fd).map_err(|_| denied())
    }

    pub(crate) fn entry_exists(&self, name: &Path) -> RunnerResult<bool> {
        leaf(name)?;
        match statat(&self.fd, name, AtFlags::SYMLINK_NOFOLLOW) {
            Ok(_) => Ok(true),
            Err(rustix::io::Errno::NOENT) => Ok(false),
            Err(_) => Err(denied()),
        }
    }

    pub(crate) fn entries(&self) -> RunnerResult<Vec<PathBuf>> {
        self.entries_bounded(4096)
    }

    pub(crate) fn entries_bounded(&self, maximum: usize) -> RunnerResult<Vec<PathBuf>> {
        let directory = rustix::fs::Dir::read_from(&self.fd).map_err(|_| denied())?;
        let mut names = Vec::new();
        for entry in directory {
            let entry = entry.map_err(|_| denied())?;
            let name = entry.file_name().to_bytes();
            if name == b"." || name == b".." {
                continue;
            }
            if names.len() == maximum {
                return Err(denied());
            }
            names.push(PathBuf::from(std::ffi::OsStr::from_bytes(name)));
        }
        Ok(names)
    }

    pub(crate) fn create_private(&self, name: &Path) -> RunnerResult<File> {
        leaf(name)?;
        let fd = openat(
            &self.fd,
            name,
            OFlags::RDWR | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::from_raw_mode(0o600),
        )
        .map_err(|_| denied())?;
        fchmod(&fd, Mode::from_raw_mode(0o600)).map_err(|_| denied())?;
        self.sync()?;
        Ok(File::from(fd))
    }

    /// Mutation uses the protected directory and its exclusive owner lock.
    /// A substituted leaf must never authorize moving or deleting that leaf.
    pub(crate) fn require_file_identity(&self, name: &Path, file: &File) -> RunnerResult<()> {
        leaf(name)?;
        let held = fstat(file).map_err(|_| denied())?;
        let entry = statat(&self.fd, name, AtFlags::SYMLINK_NOFOLLOW).map_err(|_| denied())?;
        if held.st_mode & nix::libc::S_IFMT != nix::libc::S_IFREG
            || held.st_nlink != 1
            || (held.st_dev, held.st_ino) != (entry.st_dev, entry.st_ino)
        {
            return Err(denied());
        }
        Ok(())
    }

    /// Returns false on collision. The caller records a successful promotion
    /// before syncing, so a sync failure cannot release its storage charge.
    pub(crate) fn promote_file(
        &self,
        name: &Path,
        file: &File,
        destination: &Self,
        target: &Path,
    ) -> RunnerResult<bool> {
        self.require_file_identity(name, file)?;
        leaf(target)?;
        match rustix::fs::renameat_with(
            &self.fd,
            name,
            &destination.fd,
            target,
            rustix::fs::RenameFlags::NOREPLACE,
        ) {
            Ok(()) => Ok(true),
            Err(rustix::io::Errno::EXIST) => Ok(false),
            Err(_) => Err(denied()),
        }
    }

    pub(crate) fn remove_file(&self, name: &Path, file: &File) -> RunnerResult<()> {
        self.require_file_identity(name, file)?;
        rustix::fs::unlinkat(&self.fd, name, AtFlags::empty()).map_err(|_| denied())
    }

    pub(crate) fn lock(&self, name: &Path) -> RunnerResult<nix::fcntl::Flock<File>> {
        leaf(name)?;
        let fd = openat(
            &self.fd,
            name,
            OFlags::RDWR | OFlags::CREATE | OFlags::NOFOLLOW | OFlags::CLOEXEC | OFlags::NONBLOCK,
            Mode::from_raw_mode(0o600),
        )
        .map_err(|_| denied())?;
        let meta = fstat(&fd).map_err(|_| denied())?;
        if !trusted_file(
            meta.st_uid,
            meta.st_mode,
            meta.st_nlink == 1,
            FileRole::Configuration { private: true },
        ) {
            return Err(denied());
        }
        nix::fcntl::Flock::lock(File::from(fd), nix::fcntl::FlockArg::LockExclusiveNonblock)
            .map_err(|_| denied())
    }

    pub(crate) fn child_directory(&self, name: &Path) -> RunnerResult<Self> {
        leaf(name)?;
        let created = match mkdirat(&self.fd, name, Mode::from_raw_mode(0o700)) {
            Ok(()) => true,
            Err(rustix::io::Errno::EXIST) => false,
            Err(_) => return Err(denied()),
        };
        let directory = self.open_directory(name)?;
        if created {
            fchmod(&directory.fd, Mode::from_raw_mode(0o700)).map_err(|_| denied())?;
            fsync(&directory.fd).map_err(|_| denied())?;
            fsync(&self.fd).map_err(|_| denied())?;
        }
        Ok(directory)
    }

    pub(crate) fn open_directory(&self, name: &Path) -> RunnerResult<Self> {
        leaf(name)?;
        let fd = openat(
            &self.fd,
            name,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(|_| denied())?;
        verify_directory(&fd)?;
        Ok(Self { fd })
    }

    pub(crate) fn copy_immutable(
        &self,
        name: &Path,
        reader: &mut impl Read,
        expected_digest: &str,
        expected_bytes: u64,
    ) -> RunnerResult<()> {
        use sha2::{Digest, Sha256};
        leaf(name)?;
        let fd = openat(
            &self.fd,
            name,
            OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::from_raw_mode(0o400),
        )
        .map_err(|_| denied())?;
        let mut file = File::from(fd);
        let mut hash = Sha256::new();
        let mut buffer = [0; 64 * 1024];
        let mut total = 0u64;
        let mut reader = reader.take(expected_bytes.checked_add(1).ok_or_else(denied)?);
        loop {
            let length = reader.read(&mut buffer)?;
            if length == 0 {
                break;
            }
            total = total.checked_add(length as u64).ok_or_else(denied)?;
            if total > expected_bytes {
                return Err(denied());
            }
            hash.update(&buffer[..length]);
            file.write_all(&buffer[..length])?;
        }
        if total != expected_bytes
            || format!("sha256:{}", hex::encode(hash.finalize())) != expected_digest
        {
            return Err(denied());
        }
        file.sync_all()?;
        fchmod(&file, Mode::from_raw_mode(0o444)).map_err(|_| denied())?;
        file.sync_all()?;
        fsync(&self.fd).map_err(|_| denied())
    }

    pub fn open_file(&self, name: &Path, role: FileRole, maximum_bytes: u64) -> RunnerResult<File> {
        leaf(name)?;
        let fd = openat(
            &self.fd,
            name,
            OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC | OFlags::NONBLOCK,
            Mode::empty(),
        )
        .map_err(|_| denied())?;
        let meta = fstat(&fd).map_err(|_| denied())?;
        if !trusted_file(meta.st_uid, meta.st_mode, meta.st_nlink == 1, role)
            || meta.st_size < 0
            || meta.st_size as u64 > maximum_bytes
        {
            return Err(denied());
        }
        Ok(File::from(fd))
    }

    /// Exclusive publication: existing entries, including dangling links, win.
    pub(crate) fn create_immutable(&self, name: &Path, bytes: &[u8]) -> RunnerResult<()> {
        leaf(name)?;
        let fd = openat(
            &self.fd,
            name,
            OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::from_raw_mode(0o400),
        )
        .map_err(|_| denied())?;
        fchmod(&fd, Mode::from_raw_mode(0o400)).map_err(|_| denied())?;
        let mut file = File::from(fd);
        file.write_all(bytes)?;
        file.sync_all()?;
        fsync(&self.fd).map_err(|_| denied())
    }
}

pub fn open_file(path: &Path, role: FileRole, maximum_bytes: u64) -> RunnerResult<File> {
    let parent = path.parent().ok_or_else(denied)?;
    let name = path.file_name().ok_or_else(denied)?;
    Directory::open(parent)?.open_file(Path::new(name), role, maximum_bytes)
}

pub(crate) fn verify_file(file: &File, role: FileRole, maximum_bytes: u64) -> RunnerResult<()> {
    let meta = fstat(file).map_err(|_| denied())?;
    if !trusted_file(meta.st_uid, meta.st_mode, meta.st_nlink == 1, role)
        || meta.st_size < 0
        || meta.st_size as u64 > maximum_bytes
    {
        return Err(denied());
    }
    Ok(())
}

pub fn read_bounded(mut file: File, maximum_bytes: u64) -> RunnerResult<Vec<u8>> {
    let limit = maximum_bytes.checked_add(1).ok_or_else(denied)?;
    let mut bytes = Vec::new();
    (&mut file).take(limit).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > maximum_bytes {
        return Err(denied());
    }
    Ok(bytes)
}

fn leaf(path: &Path) -> RunnerResult<()> {
    let mut components = path.components();
    if !matches!(components.next(), Some(Component::Normal(_))) || components.next().is_some() {
        return Err(denied());
    }
    Ok(())
}

fn verify_directory(fd: &OwnedFd) -> RunnerResult<()> {
    let meta = fstat(fd).map_err(|_| denied())?;
    if meta.st_uid != 0
        || meta.st_mode & nix::libc::S_IFMT != nix::libc::S_IFDIR
        || meta.st_mode & 0o022 != 0
    {
        return Err(denied());
    }
    Ok(())
}

fn trusted_file(uid: u32, mode: u32, one_link: bool, role: FileRole) -> bool {
    uid == 0
        && one_link
        && mode & nix::libc::S_IFMT == nix::libc::S_IFREG
        && match role {
            FileRole::Immutable { executable } => {
                mode & 0o222 == 0 && (!executable || mode & 0o111 != 0)
            }
            FileRole::Configuration { private } => {
                mode & 0o022 == 0 && (!private || mode & 0o077 == 0)
            }
        }
}

fn denied() -> RunnerError {
    RunnerError::new(
        "filesystem_custody_denied",
        "trusted filesystem operation rejected",
    )
}

#[cfg(test)]
mod tests;
