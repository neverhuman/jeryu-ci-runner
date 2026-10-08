//! Cross-process launch/deletion interlock. Plain files retain a kernel flock;
//! no destructor may issue LOCK_UN on the inherited open file description.
use super::*;
use rustix::fs::{FlockOperation, flock};

pub(crate) fn create(node: &Path, record: &ResourceRecord) -> RunnerResult<fs::File> {
    let directory = node.join("fences");
    if !directory.exists() {
        fs::create_dir(&directory)?;
    }
    trusted_directory(&directory)?;
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(nix::libc::O_NOFOLLOW)
        .open(directory.join(format!("{}.lock", record.resource_id)))?;
    flock(&file, FlockOperation::NonBlockingLockShared)
        .map_err(|_| failed("microvm_launch_fence_busy"))?;
    file.sync_all()?;
    fs::File::open(directory)?.sync_all()?;
    Ok(file)
}

pub(crate) fn bind(node: &Path, resource_id: &str, inherited: &fs::File) -> RunnerResult<()> {
    custody(inherited)?;
    let directory = node.join("fences");
    trusted_directory(&directory)?;
    let current = fs::OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_NOFOLLOW)
        .open(directory.join(format!("{resource_id}.lock")))?;
    custody(&current)?;
    let expected = current.metadata()?;
    let actual = inherited.metadata()?;
    verify_inode(&expected, &actual)?;
    flock(inherited, FlockOperation::NonBlockingLockShared)
        .map_err(|_| failed("microvm_launch_fence_busy"))?;
    Ok(())
}

pub(crate) fn exclusive(node: &Path, record: &ResourceRecord) -> RunnerResult<Option<fs::File>> {
    let directory = node.join("fences");
    if directory.exists() {
        trusted_directory(&directory)?;
    }
    let path = directory.join(format!("{}.lock", record.resource_id));
    let file = match fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(nix::libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(file) => file,
        Err(error)
            if error.kind() == std::io::ErrorKind::NotFound
                && (record.deadline.is_none()
                    || matches!(record.state, crate::journal::ResourceState::Cleaning)) =>
        {
            return Ok(None);
        }
        Err(_) => return Err(failed("microvm_launch_fence_missing")),
    };
    custody(&file)?;
    // Never block unrelated reconciliation for a living guardian.
    flock(&file, FlockOperation::NonBlockingLockExclusive)
        .map_err(|_| failed("microvm_launch_fence_busy"))?;
    Ok(Some(file))
}

pub(crate) fn remove(
    node: &Path,
    record: &ResourceRecord,
    lock: Option<&fs::File>,
) -> RunnerResult<()> {
    let Some(lock) = lock else {
        return Ok(());
    };
    let directory = node.join("fences");
    let path = directory.join(format!("{}.lock", record.resource_id));
    let before = lock.metadata()?;
    let current = fs::symlink_metadata(&path)?;
    if (before.dev(), before.ino()) != (current.dev(), current.ino()) || !current.is_file() {
        return Err(failed("microvm_launch_fence_custody_denied"));
    }
    fs::remove_file(path)?;
    fs::File::open(directory)?.sync_all()?;
    Ok(())
}

pub(crate) fn require_owned(node: &Path, records: &[ResourceRecord]) -> RunnerResult<()> {
    let directory = node.join("fences");
    if !directory.exists() {
        return Ok(());
    }
    trusted_directory(&directory)?;
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let id = name
            .strip_suffix(".lock")
            .filter(|id| {
                id.len() == 32
                    && id
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            })
            .ok_or_else(|| failed("microvm_launch_fence_unknown"))?;
        if !records
            .iter()
            .any(|record| record.resource_id == id && record.deadline.is_some())
        {
            return Err(failed("microvm_launch_fence_unknown"));
        }
        let file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(nix::libc::O_NOFOLLOW)
            .open(entry.path())?;
        custody(&file)?;
    }
    Ok(())
}
fn verify_inode(expected: &fs::Metadata, actual: &fs::Metadata) -> RunnerResult<()> {
    if (expected.dev(), expected.ino()) != (actual.dev(), actual.ino()) {
        return Err(failed("microvm_launch_fence_custody_denied"));
    }
    Ok(())
}
fn custody(file: &fs::File) -> RunnerResult<()> {
    let meta = file.metadata()?;
    if !meta.is_file()
        || meta.uid() != 0
        || meta.mode() & 0o077 != 0
        || meta.nlink() != 1
        || meta.len() != 0
    {
        return Err(failed("microvm_launch_fence_custody_denied"));
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Command, Stdio};
    #[test]
    fn inherited_inode_cannot_bind_a_replacement_at_the_same_path() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("lock");
        let original = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .unwrap();
        flock(&original, FlockOperation::LockShared).unwrap();
        verify_inode(&path.metadata().unwrap(), &original.metadata().unwrap()).unwrap();
        fs::rename(&path, temp.path().join("retired.lock")).unwrap();
        fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .unwrap();
        assert_eq!(
            verify_inode(&path.metadata().unwrap(), &original.metadata().unwrap())
                .unwrap_err()
                .code(),
            "microvm_launch_fence_custody_denied"
        );
    }
    #[test]
    fn child_keeps_inherited_lock_after_parent_closes_without_unlock() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("lock");
        let parent = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        flock(&parent, FlockOperation::LockShared).unwrap();
        let (mut ready, child_ready) = UnixStream::pair().unwrap();
        let mut child = Command::new("/bin/sh")
            .args(["-c", "printf ready >&2; read release"])
            .stdin(Stdio::piped())
            .stdout(Stdio::from(parent.try_clone().unwrap()))
            .stderr(Stdio::from(OwnedFd::from(child_ready)))
            .spawn()
            .unwrap();
        ready
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut message = [0; 5];
        ready.read_exact(&mut message).unwrap();
        drop(parent);
        let contender = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        assert_eq!(
            flock(&contender, FlockOperation::NonBlockingLockExclusive),
            Err(rustix::io::Errno::WOULDBLOCK)
        );
        child.stdin.take().unwrap().write_all(b"release\n").unwrap();
        assert!(child.wait().unwrap().success());
        flock(&contender, FlockOperation::NonBlockingLockExclusive).unwrap();
    }
}
