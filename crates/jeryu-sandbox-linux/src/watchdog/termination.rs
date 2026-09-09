//! A cgroup control belongs to one launch-created leaf, never a submitted path.

use crate::cgroup_fs::{
    enable_memory_and_pids, open_parent, openat, remove_exact, require_cgroup2, unique_leaf_name,
    write_control,
};
use jeryu_runner_core::sandbox::CgroupLimits;
use std::ffi::{CStr, CString};
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

#[derive(Debug)]
pub(crate) struct CgroupControl {
    parent: File,
    directory: File,
    name: CString,
    procs: File,
    kill: File,
    events: File,
}

impl CgroupControl {
    pub(crate) fn create(parent: &Path, limits: &CgroupLimits, strict: bool) -> io::Result<Self> {
        let parent = open_parent(parent)?;
        let metadata = parent.metadata()?;
        // The delegated parent belongs to this supervisor identity. Job access
        // to it must separately be denied by the execution sandbox/service.
        // SAFETY: geteuid only reads this process's effective identity.
        if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o022 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "cgroup parent must be supervisor-owned and not writable by other users",
            ));
        }
        enable_memory_and_pids(&parent)?;
        let _ = write_control(&parent, c"cgroup.subtree_control", b"+cpu");
        let name = unique_leaf_name("jeryu-job")?;
        // SAFETY: mkdirat exclusively creates one leaf under the held parent.
        if unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Self::open_created(parent, name, limits, strict, |parent, name| {
            openat(parent, name, libc::O_RDONLY | libc::O_DIRECTORY)
        })
    }

    fn open_created(
        parent: File,
        name: CString,
        limits: &CgroupLimits,
        strict: bool,
        open_leaf: impl FnOnce(&File, &CStr) -> io::Result<File>,
    ) -> io::Result<Self> {
        // Without an open leaf identity, cleanup cannot safely guess which
        // directory to remove. Retain the generated name for reconciliation.
        let directory = open_leaf(&parent, &name).map_err(|err| {
            io::Error::other(format!(
                "owned_cgroup={}: created leaf could not be opened; cleanup unresolved: {err}",
                name.to_string_lossy()
            ))
        })?;
        let setup: io::Result<(File, File, File)> = (|| {
            require_cgroup2(&directory)?;
            let memory = write_control(
                &directory,
                c"memory.max",
                limits.memory_max_bytes.to_string().as_bytes(),
            );
            if strict {
                memory?;
            }
            let pids = write_control(
                &directory,
                c"pids.max",
                limits.pids_max.to_string().as_bytes(),
            );
            if strict {
                pids?;
            }
            let _ = write_control(
                &directory,
                c"cpu.weight",
                limits.cpu_weight.clamp(1, 10_000).to_string().as_bytes(),
            );
            let procs = openat(&directory, c"cgroup.procs", libc::O_WRONLY)?;
            let kill = openat(&directory, c"cgroup.kill", libc::O_WRONLY)?;
            let events = openat(&directory, c"cgroup.events", libc::O_RDONLY)?;
            for file in [&procs, &kill, &events] {
                require_cgroup2(file)?;
            }
            Ok((procs, kill, events))
        })();
        match setup {
            Ok((procs, kill, events)) => Ok(Self {
                parent,
                directory,
                name,
                procs,
                kill,
                events,
            }),
            Err(error) => match remove_exact(&parent, &directory, &name) {
                Ok(()) => Err(io::Error::new(
                    error.kind(),
                    format!(
                        "owned_cgroup={}: {error}; empty leaf removed",
                        name.to_string_lossy()
                    ),
                )),
                Err(cleanup) => Err(io::Error::other(format!(
                    "owned_cgroup={}: {error}; cgroup cleanup unresolved: {cleanup}",
                    name.to_string_lossy()
                ))),
            },
        }
    }

    pub(crate) fn procs(&self) -> io::Result<File> {
        self.procs.try_clone()
    }

    pub(crate) fn label(&self) -> String {
        format!("{}", self.name.to_string_lossy())
    }

    pub(crate) fn kill(&mut self) -> io::Result<()> {
        self.kill.seek(SeekFrom::Start(0))?;
        self.kill.write_all(b"1")
    }

    pub(crate) fn empty(&mut self) -> io::Result<bool> {
        self.events.seek(SeekFrom::Start(0))?;
        let mut bytes = Vec::new();
        Read::by_ref(&mut self.events)
            .take(4097)
            .read_to_end(&mut bytes)?;
        parse_events(&bytes)
    }

    pub(crate) fn cleanup(&mut self) -> io::Result<()> {
        if !self.empty()? {
            return Err(io::Error::other(
                "owned cgroup remains populated; cleanup unresolved",
            ));
        }
        remove_exact(&self.parent, &self.directory, &self.name)
    }
}

fn parse_events(bytes: &[u8]) -> io::Result<bool> {
    if bytes.len() > 4096 {
        return Err(io::Error::other("oversized cgroup events"));
    }
    let text = std::str::from_utf8(bytes).map_err(io::Error::other)?;
    let mut values = text
        .lines()
        .filter_map(|line| line.strip_prefix("populated "));
    let empty = match values.next() {
        Some("0") => true,
        Some("1") => false,
        _ => return Err(io::Error::other("invalid or missing cgroup population")),
    };
    if values.next().is_some() {
        return Err(io::Error::other("duplicate cgroup population"));
    }
    Ok(empty)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn population_requires_one_bounded_unambiguous_value() {
        assert!(parse_events(b"populated 0\nfrozen 0\n").unwrap());
        assert!(!parse_events(b"populated 1\n").unwrap());
        for bytes in [
            b"populated 0\npopulated 1\n".as_slice(),
            b"populated 2\n",
            b"frozen 0\n",
        ] {
            assert!(parse_events(bytes).is_err());
        }
        assert!(parse_events(&vec![b' '; 4097]).is_err());
    }

    #[test]
    fn fake_filesystem_is_rejected_without_mutation() {
        let root = tempfile::tempdir().unwrap();
        let limits = CgroupLimits {
            memory_max_bytes: 1024,
            pids_max: 4,
            cpu_weight: 100,
            io_weight: 100,
        };
        assert!(CgroupControl::create(root.path(), &limits, false).is_err());
        assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
    }

    #[test]
    fn replaced_owned_leaf_is_retained() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir(root.path().join("job")).unwrap();
        let parent = File::open(root.path()).unwrap();
        let held = openat(&parent, c"job", libc::O_RDONLY | libc::O_DIRECTORY).unwrap();
        std::fs::rename(root.path().join("job"), root.path().join("original")).unwrap();
        std::fs::create_dir(root.path().join("job")).unwrap();
        assert!(remove_exact(&parent, &held, c"job").is_err());
        assert!(root.path().join("job").is_dir());
        assert!(root.path().join("original").is_dir());
    }

    #[test]
    fn post_creation_open_failure_reports_the_retained_leaf() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir(root.path().join("jeryu-job-owned.scope")).unwrap();
        let limits = CgroupLimits {
            memory_max_bytes: 1024,
            pids_max: 4,
            cpu_weight: 100,
            io_weight: 100,
        };
        let error = CgroupControl::open_created(
            File::open(root.path()).unwrap(),
            CString::new("jeryu-job-owned.scope").unwrap(),
            &limits,
            true,
            |_, _| Err(io::Error::from_raw_os_error(libc::EMFILE)),
        )
        .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("owned_cgroup=jeryu-job-owned.scope")
        );
        assert!(error.to_string().contains("cleanup unresolved"));
        assert!(
            error
                .to_string()
                .contains(&io::Error::from_raw_os_error(libc::EMFILE).to_string())
        );
        assert!(root.path().join("jeryu-job-owned.scope").is_dir());
    }

    #[test]
    fn post_creation_setup_and_cleanup_errors_retain_identity_and_both_causes() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("jeryu-job-owned.scope");
        std::fs::create_dir(&path).unwrap();
        let limits = CgroupLimits {
            memory_max_bytes: 1024,
            pids_max: 4,
            cpu_weight: 100,
            io_weight: 100,
        };
        let error = CgroupControl::open_created(
            File::open(root.path()).unwrap(),
            CString::new("jeryu-job-owned.scope").unwrap(),
            &limits,
            true,
            |parent, name| {
                let held = openat(parent, name, libc::O_RDONLY | libc::O_DIRECTORY)?;
                std::fs::rename(&path, root.path().join("original"))?;
                std::fs::create_dir(&path)?;
                Ok(held)
            },
        )
        .unwrap_err();
        let message = error.to_string();
        assert!(message.contains("owned_cgroup=jeryu-job-owned.scope"));
        assert!(message.contains("expected cgroup v2"));
        assert!(message.contains("owned cgroup name was replaced"));
        assert!(message.contains("cleanup unresolved"));
        assert!(path.is_dir());
        assert!(root.path().join("original").is_dir());
    }
}
