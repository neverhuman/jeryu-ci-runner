//! Descriptor-bound cgroup admission and single-leaf filesystem operations.

use std::ffi::{CStr, CString};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

pub(crate) fn open_parent(path: &Path) -> io::Result<File> {
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    require_cgroup2(&directory)?;
    Ok(directory)
}

pub(crate) fn openat(directory: &File, name: &CStr, flags: i32) -> io::Result<File> {
    // SAFETY: directory and name are live, and the returned descriptor is owned.
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: successful openat returned a new descriptor.
    Ok(unsafe { File::from_raw_fd(fd) })
}

pub(crate) fn require_cgroup2(file: &File) -> io::Result<()> {
    // SAFETY: fstatfs initializes this structure through a valid pointer.
    let mut filesystem: libc::statfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstatfs(file.as_raw_fd(), &mut filesystem) } != 0 {
        return Err(io::Error::last_os_error());
    }
    if filesystem.f_type != 0x6367_7270 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "expected cgroup v2",
        ));
    }
    Ok(())
}

pub(crate) fn write_control(directory: &File, name: &CStr, bytes: &[u8]) -> io::Result<()> {
    let mut file = openat(directory, name, libc::O_WRONLY)?;
    require_cgroup2(&file)?;
    file.write_all(bytes)
}

/// Enabling only pids after a failed memory enable can change domain topology.
/// Always submit one combined command and require the kernel's bare-name reply,
/// even when this parent came from cached or caller-supplied capabilities.
pub(crate) fn enable_memory_and_pids(parent: &File) -> io::Result<()> {
    let mut control = openat(parent, c"cgroup.subtree_control", libc::O_RDWR)?;
    require_cgroup2(&control)?;
    enable_control(&mut control)
}

fn enable_control(control: &mut (impl Read + Write + Seek)) -> io::Result<()> {
    control.write_all(b"+pids +memory")?;
    control.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::new();
    Read::by_ref(control).take(4097).read_to_end(&mut bytes)?;
    enabled_memory_and_pids(&bytes)
}

fn enabled_memory_and_pids(bytes: &[u8]) -> io::Result<()> {
    if bytes.len() > 4096 {
        return Err(io::Error::other("oversized cgroup controller readback"));
    }
    let enabled = std::str::from_utf8(bytes).map_err(io::Error::other)?;
    if !["memory", "pids"].iter().all(|required| {
        enabled
            .split_ascii_whitespace()
            .any(|actual| actual == *required)
    }) {
        return Err(io::Error::other(
            "cgroup memory and pids controllers were not enabled",
        ));
    }
    Ok(())
}

pub(crate) fn unique_leaf_name(prefix: &str) -> io::Result<CString> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    CString::new(format!(
        "{prefix}-{}-{}-{}.scope",
        std::process::id(),
        jeryu_runner_core::receipt::now_ms(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ))
    .map_err(io::Error::other)
}

pub(crate) fn remove_exact(parent: &File, directory: &File, name: &CStr) -> io::Result<()> {
    let current = openat(parent, name, libc::O_RDONLY | libc::O_DIRECTORY)?;
    let expected = directory.metadata()?;
    let observed = current.metadata()?;
    if (observed.dev(), observed.ino()) != (expected.dev(), expected.ino()) {
        return Err(io::Error::other(
            "owned cgroup name was replaced; cleanup unresolved",
        ));
    }
    // Only this leaf is removed. Kernel cgroup rmdir refuses populated groups
    // and groups with children. No recursive deletion or path-following occurs.
    // SAFETY: parent is held and name is a single generated component.
    if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn controller_readback_requires_both_kernel_names() {
        for valid in [b"memory pids\n".as_slice(), b"cpu pids memory io\n"] {
            enabled_memory_and_pids(valid).unwrap();
        }
        for invalid in [
            b"".as_slice(),
            b"memory\n",
            b"pids\n",
            b"+pids +memory",
            b"memory_extra pids\n",
            b"memory pids_extra\n",
            b"memory pids\xff",
        ] {
            assert!(enabled_memory_and_pids(invalid).is_err(), "{invalid:?}");
        }
        assert!(enabled_memory_and_pids(&vec![b' '; 4097]).is_err());
    }

    #[test]
    fn failed_write_cannot_be_replaced_by_existing_enabled_names() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("control");
        std::fs::write(&path, b"memory pids\n").unwrap();
        let mut readonly = File::open(&path).unwrap();
        assert!(enable_control(&mut readonly).is_err());
        assert_eq!(std::fs::read(path).unwrap(), b"memory pids\n");
    }

    #[test]
    fn successful_write_requires_readback_and_rejects_command_echo() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("control");
        std::fs::write(&path, b"").unwrap();
        let mut writeonly = OpenOptions::new().write(true).open(&path).unwrap();
        assert!(enable_control(&mut writeonly).is_err());
        let mut ordinary = OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .unwrap();
        assert!(enable_control(&mut ordinary).is_err());
    }
}
