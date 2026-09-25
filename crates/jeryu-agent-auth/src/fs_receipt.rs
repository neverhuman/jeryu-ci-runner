use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use sha2::{Digest, Sha256};

use crate::error::fs_error;
use crate::{AgentAuthError, AgentToolKind, AuthFileReceipt};

pub(crate) fn auth_dir(data_home: &Path, tool: AgentToolKind) -> PathBuf {
    data_home.join("agent-auth").join(tool.as_str())
}

pub(crate) fn create_private_dir(path: &Path) -> Result<(), AgentAuthError> {
    std::fs::create_dir_all(path).map_err(fs_error)?;
    set_dir_private(path)?;
    Ok(())
}

pub(crate) fn copy_imported_files(
    files: &[AuthFileReceipt],
    target_dir: &Path,
) -> Result<Vec<AuthFileReceipt>, AgentAuthError> {
    let mut copied = Vec::new();
    for file in files {
        let name = file.path.file_name().ok_or_else(|| {
            AgentAuthError::new(
                "agent_auth_invalid_path",
                "materialize imported auth",
                format!(
                    "imported auth path '{}' has no file name",
                    file.path.display()
                ),
                &["remove the malformed auth file and re-import"],
                "docs/testing.md#workcells",
                "rerun cargo test -p jeryu-agent-auth --jobs 40",
            )
        })?;
        copied.push(copy_private_file(&file.path, &target_dir.join(name))?);
    }
    Ok(copied)
}

pub(crate) fn copy_private_file(
    source: &Path,
    target: &Path,
) -> Result<AuthFileReceipt, AgentAuthError> {
    let bytes = std::fs::read(source).map_err(fs_error)?;
    write_private_file(target, &bytes)
}

pub(crate) fn write_private_file(
    target: &Path,
    bytes: &[u8],
) -> Result<AuthFileReceipt, AgentAuthError> {
    if let Some(parent) = target.parent() {
        create_private_dir(parent)?;
    }
    let mut file = open_private_target(target)?;
    file.write_all(bytes).map_err(fs_error)?;
    file.sync_all().map_err(fs_error)?;
    set_file_private(target)?;
    receipt_for_file(target)
}

/// Write `bytes` to `target` so readers never observe a partial credential: the
/// content lands in an unpredictable sibling created 0600 and is renamed over
/// `target`. The temporary file is created exclusively, so a pre-planted file or
/// symlink at its path is never followed, and both the file and the directory
/// entry are flushed before the write is reported.
pub(crate) fn write_private_file_atomic(
    target: &Path,
    bytes: &[u8],
) -> Result<AuthFileReceipt, AgentAuthError> {
    if let Some(parent) = target.parent() {
        create_private_dir(parent)?;
    }
    let (pending, mut file) = create_pending_sibling(target)?;
    let write = (|| {
        file.write_all(bytes)?;
        file.sync_all()
    })();
    if let Err(error) = write {
        let _ = std::fs::remove_file(&pending);
        return Err(fs_error(error));
    }
    drop(file);
    set_file_private(&pending)?;
    if let Err(error) = std::fs::rename(&pending, target) {
        let _ = std::fs::remove_file(&pending);
        return Err(fs_error(error));
    }
    sync_parent_dir(target)?;
    receipt_for_file(target)
}

/// Create a fresh 0600 file next to `target` under a name no other process can
/// predict, retrying while the name happens to be taken.
fn create_pending_sibling(target: &Path) -> Result<(PathBuf, File), AgentAuthError> {
    let base = target
        .file_name()
        .map(std::ffi::OsStr::to_os_string)
        .ok_or_else(|| {
            AgentAuthError::new(
                "agent_auth_invalid_path",
                "materialize private file",
                format!("target path '{}' has no file name", target.display()),
                &["choose a target path with a file name"],
                "docs/testing.md#workcells",
                "rerun cargo test -p jeryu-agent-auth --jobs 40",
            )
        })?;
    let mut last: Option<std::io::Error> = None;
    for _ in 0..32 {
        let mut name = base.clone();
        name.push(format!(".{:016x}.pending", pending_nonce()));
        let candidate = target.with_file_name(name);
        match private_create_new(&candidate) {
            Ok(file) => return Ok((candidate, file)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                last = Some(error);
            }
            Err(error) => return Err(fs_error(error)),
        }
    }
    Err(fs_error(last.unwrap_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            "no free staging name next to the credential",
        )
    })))
}

/// Nonce for temporary credential names: a per-process random seed mixed with a
/// counter, so names are neither guessable nor repeated within a process.
fn pending_nonce() -> u64 {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| u64::try_from(since.as_nanos()).unwrap_or(u64::MAX));
    let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
    let mut hasher = Sha256::new();
    hasher.update(seed.to_le_bytes());
    hasher.update(counter.to_le_bytes());
    hasher.update(std::process::id().to_le_bytes());
    let digest = hasher.finalize();
    u64::from_le_bytes(digest[..8].try_into().expect("sha256 yields 32 bytes"))
}

#[cfg(unix)]
fn private_create_new(path: &Path) -> std::io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
}

#[cfg(not(unix))]
fn private_create_new(path: &Path) -> std::io::Result<File> {
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
}

/// Open `target` for a full rewrite, creating it 0600 rather than at the umask.
#[cfg(unix)]
fn open_private_target(target: &Path) -> Result<File, AgentAuthError> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(target)
        .map_err(fs_error)
}

#[cfg(not(unix))]
fn open_private_target(target: &Path) -> Result<File, AgentAuthError> {
    std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(target)
        .map_err(fs_error)
}

/// Flush the directory entry so the renamed credential survives a crash.
#[cfg(unix)]
fn sync_parent_dir(target: &Path) -> Result<(), AgentAuthError> {
    let Some(parent) = target.parent() else {
        return Ok(());
    };
    File::open(parent)
        .and_then(|dir| dir.sync_all())
        .map_err(fs_error)
}

#[cfg(not(unix))]
fn sync_parent_dir(_target: &Path) -> Result<(), AgentAuthError> {
    Ok(())
}

pub(crate) fn receipts_for_dir(path: &Path) -> Result<Vec<AuthFileReceipt>, AgentAuthError> {
    let mut files = Vec::new();
    for entry in std::fs::read_dir(path).map_err(fs_error)? {
        let entry = entry.map_err(fs_error)?;
        if entry.file_type().map_err(fs_error)?.is_file() {
            files.push(receipt_for_file(&entry.path())?);
        }
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

fn receipt_for_file(path: &Path) -> Result<AuthFileReceipt, AgentAuthError> {
    let bytes = std::fs::read(path).map_err(fs_error)?;
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    Ok(AuthFileReceipt {
        path: path.to_path_buf(),
        digest: format!("sha256:{}", hex::encode(hasher.finalize())),
        mode: file_mode(path)?,
    })
}

#[cfg(unix)]
fn set_file_private(path: &Path) -> Result<(), AgentAuthError> {
    use std::os::unix::fs::PermissionsExt;
    let mut perms = std::fs::metadata(path).map_err(fs_error)?.permissions();
    perms.set_mode(0o600);
    std::fs::set_permissions(path, perms).map_err(fs_error)
}

#[cfg(not(unix))]
fn set_file_private(_path: &Path) -> Result<(), AgentAuthError> {
    Ok(())
}

#[cfg(unix)]
fn set_dir_private(path: &Path) -> Result<(), AgentAuthError> {
    use std::os::unix::fs::PermissionsExt;
    let mut perms = std::fs::metadata(path).map_err(fs_error)?.permissions();
    perms.set_mode(0o700);
    std::fs::set_permissions(path, perms).map_err(fs_error)
}

#[cfg(not(unix))]
fn set_dir_private(_path: &Path) -> Result<(), AgentAuthError> {
    Ok(())
}

#[cfg(unix)]
fn file_mode(path: &Path) -> Result<String, AgentAuthError> {
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(path)
        .map_err(fs_error)?
        .permissions()
        .mode()
        & 0o777;
    Ok(format!("{mode:04o}"))
}

#[cfg(not(unix))]
fn file_mode(_path: &Path) -> Result<String, AgentAuthError> {
    Ok("platform-default".to_string())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn atomic_write_lands_private_and_leaves_no_temporary() {
        let temp = tempfile::tempdir().expect("tempdir");
        let target = temp.path().join("nested/auth.json");

        let receipt = write_private_file_atomic(&target, b"token").expect("write succeeds");

        assert_eq!(receipt.mode, "0600");
        assert_eq!(std::fs::read(&target).expect("read back"), b"token");
        let leftovers: Vec<_> = std::fs::read_dir(target.parent().expect("parent"))
            .expect("read dir")
            .map(|entry| entry.expect("entry").file_name())
            .filter(|name| name != "auth.json")
            .collect();
        assert!(leftovers.is_empty(), "stray temporaries: {leftovers:?}");
    }

    #[test]
    fn atomic_write_does_not_follow_a_planted_pending_symlink() {
        let temp = tempfile::tempdir().expect("tempdir");
        let dir = temp.path().join("agent-auth");
        std::fs::create_dir_all(&dir).expect("dir");
        let target = dir.join("auth.json");
        let stolen = temp.path().join("stolen.json");
        std::os::unix::fs::symlink(&stolen, dir.join("auth.json.pending")).expect("symlink");

        let receipt = write_private_file_atomic(&target, b"token").expect("write succeeds");

        assert_eq!(receipt.mode, "0600");
        assert_eq!(std::fs::read(&target).expect("read back"), b"token");
        assert!(!stolen.exists(), "secret written through planted symlink");
        assert!(
            std::fs::symlink_metadata(dir.join("auth.json.pending")).is_ok(),
            "planted symlink should be left untouched"
        );
    }
}
