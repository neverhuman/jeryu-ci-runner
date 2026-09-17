//! cgroups-v2 delegation probes: find a subtree where memory/pids limits and
//! process migration really work for this unprivileged process.

use std::path::PathBuf;

/// Find a writable cgroups-v2 subtree that already has (or can be granted) the
/// `memory` and `pids` controllers via delegation.
///
/// The current process's own cgroup (`/proc/self/cgroup`) is frequently a
/// read-only `session-N.scope`. On a systemd user session the actually-delegated
/// tree is the SIBLING `user@<uid>.service` under the same `user-<uid>.slice`,
/// NOT an ancestor of the session scope — so a pure leaf->root walk misses it.
/// We therefore probe both the ancestor chain AND the user-manager service path
/// derived from the `user-<uid>.slice` ancestor, and pick the first directory we
/// can really create a child under.
pub(super) fn probe_cgroup_subtree() -> Option<PathBuf> {
    const MOUNT: &str = "/sys/fs/cgroup";
    let rel = current_cgroup_rel()?;
    let needed = ["memory", "pids"];

    let mut candidates: Vec<PathBuf> = Vec::new();

    // 1. The ancestor chain of our own leaf cgroup (deepest first below).
    let mut acc = PathBuf::from(MOUNT);
    let mut ancestors = vec![acc.clone()];
    for component in rel.trim_matches('/').split('/') {
        if component.is_empty() {
            continue;
        }
        acc.push(component);
        ancestors.push(acc.clone());
        // 2. Sibling user-manager service: when we pass a `user-<uid>.slice`,
        //    its delegated `user@<uid>.service` child is the real writable tree.
        if let Some(uid) = component
            .strip_suffix(".slice")
            .and_then(|slice| slice.strip_prefix("user-"))
        {
            candidates.push(acc.join(format!("user@{uid}.service")));
        }
    }
    // Prefer the deepest ancestor first, then the user-manager service paths.
    candidates.extend(ancestors.into_iter().rev());

    for dir in candidates {
        if !cgroup_has_controllers(&dir, &needed) {
            continue;
        }
        // The load-bearing test is not "can I mkdir" but "can a child process
        // actually JOIN a leaf here" — cgroup-v2 delegation lets us create
        // directories under a tree whose ancestor is NOT delegated, yet refuses
        // the process migration (EACCES) because moving a process needs write on
        // the common ancestor's cgroup.procs. On a systemd session this is
        // exactly the trap: `user@<uid>.service` is writable for mkdir but a
        // process pinned in `session-N.scope` cannot migrate into it. We must
        // report cgroup enforcement as available ONLY when the join succeeds.
        if cgroup_subtree_is_enforceable(&dir) {
            return Some(dir);
        }
    }
    None
}

pub(super) fn current_cgroup_rel() -> Option<String> {
    let content = std::fs::read_to_string("/proc/self/cgroup").ok()?;
    // cgroup-v2 line is `0::<path>`.
    content
        .lines()
        .find_map(|line| line.strip_prefix("0::").map(|p| p.to_string()))
}

pub(super) fn cgroup_has_controllers(dir: &std::path::Path, needed: &[&str]) -> bool {
    let read = |name: &str| std::fs::read_to_string(dir.join(name)).unwrap_or_default();
    let available: String = format!(
        "{} {}",
        read("cgroup.controllers"),
        read("cgroup.subtree_control")
    );
    let tokens: Vec<&str> = available.split_whitespace().collect();
    needed.iter().all(|c| tokens.contains(c))
}

/// Require actual memory/pids delegation, then prove that a throwaway child can
/// join an exclusively created leaf. Migration into an unlimited child alone
/// does not establish controller enforcement.
pub(super) fn cgroup_subtree_is_enforceable(dir: &std::path::Path) -> bool {
    use crate::cgroup_fs::{
        enable_memory_and_pids, open_parent, openat, remove_exact, require_cgroup2,
        unique_leaf_name,
    };
    use std::os::fd::AsRawFd;

    let Ok(parent) = open_parent(dir) else {
        return false;
    };
    if enable_memory_and_pids(&parent).is_err() {
        return false;
    }
    let Ok(name) = unique_leaf_name("jeryu-cap-probe") else {
        return false;
    };
    let leaf = match create_probe_directory(&parent, &name) {
        Ok(leaf) => leaf,
        Err(error) => {
            eprintln!("cgroup capability probe: {error}");
            return false;
        }
    };
    let joined = openat(&leaf, c"cgroup.procs", libc::O_WRONLY)
        .and_then(|procs| {
            require_cgroup2(&procs)?;
            Ok(probe_cgroup_join(procs.as_raw_fd()))
        })
        .unwrap_or(false);
    // rmdir independently refuses populated groups. A failed cleanup is not
    // successful admission, even if the child's migration was observed.
    let removed = match remove_exact(&parent, &leaf, &name) {
        Ok(()) => true,
        Err(error) => {
            eprintln!(
                "cgroup capability probe owned_cgroup={}: cleanup unresolved: {error}",
                name.to_string_lossy()
            );
            false
        }
    };
    joined && removed
}

pub(super) fn create_probe_directory(
    parent: &std::fs::File,
    name: &std::ffi::CStr,
) -> std::io::Result<std::fs::File> {
    use crate::cgroup_fs::openat;
    use std::os::fd::AsRawFd;

    // No preexisting name is ever removed, including a prior process's leaf.
    // SAFETY: parent is held and name is one generated component.
    if unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    openat(parent, name, libc::O_RDONLY | libc::O_DIRECTORY).map_err(|error| {
        std::io::Error::other(format!(
            "owned_cgroup={}: created probe could not be opened; cleanup unresolved: {error}",
            name.to_string_lossy()
        ))
    })
}

pub(super) fn probe_cgroup_join(procs_fd: std::os::fd::RawFd) -> bool {
    use nix::errno::Errno;
    use nix::sys::wait::{WaitStatus, waitpid};
    use nix::unistd::{ForkResult, fork};

    // SAFETY: the child only writes zero (its own PID) through the already open
    // cgroup.procs descriptor and exits. No allocation or path lookup follows
    // fork, which may run concurrently with another capability cache's probe.
    match unsafe { fork() } {
        Ok(ForkResult::Child) => {
            loop {
                // SAFETY: the inherited fd and the one-byte buffer are live.
                let written = unsafe { libc::write(procs_fd, b"0".as_ptr().cast(), 1) };
                if written == -1 && Errno::last() == Errno::EINTR {
                    continue;
                }
                crate::forked_child::terminate(if written == 1 { 0 } else { 1 });
            }
        }
        Ok(ForkResult::Parent { child }) => loop {
            match waitpid(child, None) {
                Err(Errno::EINTR) => continue,
                result => break matches!(result, Ok(WaitStatus::Exited(_, 0))),
            }
        },
        Err(_) => false,
    }
}
