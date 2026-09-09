//! Fail-closed cgroup-v2 construction for the raw-Child compatibility path.

use super::{SandboxError, SandboxResult};
use crate::cgroup_fs::{
    enable_memory_and_pids, open_parent, openat, remove_exact, require_cgroup2, unique_leaf_name,
    write_control,
};
use jeryu_runner_core::sandbox::CgroupLimits;
use std::ffi::{CStr, CString};
use std::fs::File;
use std::io;
use std::os::fd::AsRawFd;
use std::path::Path;

/// Only retained until spawn succeeds. The raw Child API does not transfer an
/// owned-cgroup lifetime to its caller; this guard closes failed-launch cleanup.
pub(super) struct CgroupCleanup {
    parent: File,
    directory: File,
    name: CString,
}

impl CgroupCleanup {
    pub(super) fn cleanup(&self) -> io::Result<()> {
        remove_exact(&self.parent, &self.directory, &self.name)
    }

    pub(super) fn label(&self) -> String {
        self.name.to_string_lossy().into_owned()
    }
}

/// A cached or supplied parent must pass live controller admission. Parent,
/// leaf, limit writes and child migration stay bound to those opened identities.
pub(super) fn create_cgroup(
    parent: &Path,
    limits: &CgroupLimits,
    require_cgroup: bool,
) -> SandboxResult<(File, CgroupCleanup)> {
    let parent = open_parent(parent)
        .map_err(|error| SandboxError::new("cgroup_parent_unavailable", error.to_string()))?;
    // An optional cgroup policy permits an absent subtree, not a partially
    // enabled parent whose otherwise unlimited child may have invalid topology.
    enable_memory_and_pids(&parent)
        .map_err(|error| SandboxError::new("cgroup_controllers_unavailable", error.to_string()))?;
    let _ = write_control(&parent, c"cgroup.subtree_control", b"+cpu");
    let name = unique_leaf_name("jeryu-job")
        .map_err(|error| SandboxError::new("cgroup_create_failed", error.to_string()))?;
    // SAFETY: parent is held and name is one generated component. mkdirat is
    // exclusive; no preexisting directory can be adopted or removed here.
    if unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
        return Err(SandboxError::new(
            "cgroup_create_failed",
            io::Error::last_os_error().to_string(),
        ));
    }
    let directory = openat(&parent, &name, libc::O_RDONLY | libc::O_DIRECTORY).map_err(|error| {
        SandboxError::new(
            "cgroup_create_failed",
            format!(
                "owned_cgroup={}: created leaf could not be opened; cleanup unresolved: {error}",
                name.to_string_lossy()
            ),
        )
    })?;
    let cleanup = CgroupCleanup {
        parent,
        directory,
        name,
    };
    let setup: SandboxResult<File> = (|| {
        require_cgroup2(&cleanup.directory)
            .map_err(|error| SandboxError::new("cgroup_create_failed", error.to_string()))?;
        write_limits(limits, require_cgroup, |name, data| {
            write_control(&cleanup.directory, name, data)
        })?;
        let procs = openat(&cleanup.directory, c"cgroup.procs", libc::O_WRONLY)
            .and_then(|procs| {
                require_cgroup2(&procs)?;
                Ok(procs)
            })
            .map_err(|error| SandboxError::new("cgroup_procs_unavailable", error.to_string()))?;
        Ok(procs)
    })();
    match setup {
        Ok(procs) => Ok((procs, cleanup)),
        Err(error) => {
            let disposition = match cleanup.cleanup() {
                Ok(()) => "empty leaf removed".to_string(),
                Err(error) => format!("cleanup unresolved: {error}"),
            };
            Err(SandboxError::new(
                error.code(),
                format!(
                    "owned_cgroup={}: {}; {disposition}",
                    cleanup.label(),
                    error.message()
                ),
            ))
        }
    }
}

fn write_limits(
    limits: &CgroupLimits,
    strict: bool,
    write_file: impl Fn(&CStr, &[u8]) -> io::Result<()>,
) -> SandboxResult<()> {
    for (name, bytes, code) in [
        (
            c"memory.max",
            limits.memory_max_bytes.to_string(),
            "cgroup_memory_max_write_failed",
        ),
        (
            c"pids.max",
            limits.pids_max.to_string(),
            "cgroup_pids_max_write_failed",
        ),
    ] {
        if let Err(error) = write_file(name, bytes.as_bytes())
            && strict
        {
            return Err(SandboxError::new(
                code,
                format!(
                    "failed to write cgroup limit {}: {error}",
                    name.to_string_lossy()
                ),
            ));
        }
    }
    let _ = write_file(
        c"cpu.weight",
        limits.cpu_weight.clamp(1, 10_000).to_string().as_bytes(),
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_limits() -> CgroupLimits {
        CgroupLimits {
            memory_max_bytes: 64 * 1024 * 1024,
            cpu_weight: 100,
            pids_max: 32,
            io_weight: 100,
        }
    }

    fn forced_write_failure() -> io::Error {
        io::Error::new(
            io::ErrorKind::PermissionDenied,
            "forced cgroup write failure",
        )
    }

    #[test]
    fn supplied_non_cgroup_parent_is_rejected_for_both_policies() {
        for strict in [false, true] {
            let parent = tempfile::tempdir().expect("temp cgroup parent");
            let control = parent.path().join("cgroup.subtree_control");
            std::fs::write(&control, b"memory pids\n").unwrap();
            let result = create_cgroup(parent.path(), &test_limits(), strict);
            let error = match result {
                Err(error) => error,
                Ok(_) => panic!("a claimed subtree must be an actual cgroup"),
            };
            assert_eq!(error.code(), "cgroup_parent_unavailable");
            assert_eq!(std::fs::read(control).unwrap(), b"memory pids\n");
            assert_eq!(std::fs::read_dir(parent.path()).unwrap().count(), 1);
        }
    }

    #[test]
    fn strict_cgroup_requires_memory_and_pids_limit_writes() {
        for (filename, expected_code) in [
            (c"memory.max", "cgroup_memory_max_write_failed"),
            (c"pids.max", "cgroup_pids_max_write_failed"),
        ] {
            let error = write_limits(&test_limits(), true, |name, _| {
                if name == filename {
                    Err(forced_write_failure())
                } else {
                    Ok(())
                }
            })
            .expect_err("strict load-bearing limit writes must succeed");
            assert_eq!(error.code(), expected_code);
            assert!(error.message().contains(filename.to_str().unwrap()));
        }
    }

    #[test]
    fn non_strict_cgroup_limit_writes_remain_best_effort() {
        write_limits(&test_limits(), false, |_, _| Err(forced_write_failure())).unwrap();
    }
}
