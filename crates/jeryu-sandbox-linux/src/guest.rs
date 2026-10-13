//! Guest-only kernel primitives; the VM's PID 1 calls these after platform
//! verification. The host never uses them to launch managed workloads.
use nix::sys::socket::{
    AddressFamily, Backlog, SockFlag, SockType, VsockAddr, accept4, bind, getpeername, listen,
    socket,
};
use std::{
    collections::BTreeMap,
    fs::File,
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::process::CommandExt,
    },
    path::Path,
    process::{Child, Command, Stdio},
};

pub struct GuestListener(OwnedFd);

impl GuestListener {
    pub fn bind(port: u32) -> std::io::Result<Self> {
        let fd = socket(
            AddressFamily::Vsock,
            SockType::Stream,
            SockFlag::SOCK_CLOEXEC,
            None,
        )?;
        bind(fd.as_raw_fd(), &VsockAddr::new(u32::MAX, port))?;
        listen(&fd, Backlog::new(1)?)?;
        Ok(Self(fd))
    }
    pub fn accept_host(&self) -> std::io::Result<File> {
        let raw = accept4(self.0.as_raw_fd(), SockFlag::SOCK_CLOEXEC)?;
        // SAFETY: accept4 returned a fresh descriptor exclusively owned here.
        let owned = unsafe { OwnedFd::from_raw_fd(raw) };
        let peer: VsockAddr = getpeername(owned.as_raw_fd())?;
        if peer.cid() != 2 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "guest_peer_denied",
            ));
        }
        use nix::{
            sys::socket::{setsockopt, sockopt::SendTimeout},
            sys::time::{TimeVal, TimeValLike},
        };
        setsockopt(&owned, SendTimeout, &TimeVal::seconds(2))?;
        Ok(File::from(owned))
    }
}

/// Fixed, non-interactive Git preparation inside the guest, before agents start.
/// No host service accepts this launcher as an execution API.
pub fn spawn_workspace_git(args: &[&str], workspace: &Path) -> std::io::Result<Child> {
    if std::process::id() != 1 {
        return Err(std::io::Error::other("guest_pid1_required"));
    }
    let mut command = Command::new("/usr/bin/git");
    command
        .args([
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "core.commitGraph=false",
            "-c",
            "protocol.allow=never",
            "-c",
            "protocol.file.allow=always",
            "-c",
            "user.name=JeRyu workspace sync",
            "-c",
            "user.email=workspace-sync@jeryu.invalid",
        ])
        .args(args)
        .env_clear()
        .env("HOME", "/run/agent-home")
        .env("PATH", "/usr/bin:/bin")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        // Workspace metadata is untrusted. Ancestry must describe real objects,
        // never replacement refs, grafts, shallow cutoffs or cached fake parents.
        .env("GIT_NO_REPLACE_OBJECTS", "1")
        .env("GIT_GRAFT_FILE", "/dev/null")
        .env("GIT_SHALLOW_FILE", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_EDITOR", "/bin/false")
        .env("GIT_SEQUENCE_EDITOR", "/bin/false")
        .current_dir(workspace)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // SAFETY: only direct async-signal-safe syscalls occur between fork and exec.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1
                || libc::setgroups(0, std::ptr::null()) == -1
                || libc::setgid(1000) == -1
                || libc::setuid(1000) == -1
                || libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == -1
            {
                return Err(std::io::Error::last_os_error());
            }
            let limits = libc::rlimit {
                rlim_cur: 128,
                rlim_max: 128,
            };
            if libc::setrlimit(libc::RLIMIT_NPROC, &limits) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            let core = libc::rlimit {
                rlim_cur: 0,
                rlim_max: 0,
            };
            if libc::setrlimit(libc::RLIMIT_CORE, &core) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command.spawn()
}

pub struct GuestPty<'a> {
    pub slave: &'a OwnedFd,
    pub cgroup_procs: &'a File,
    pub pids_max: u32,
}

pub fn spawn_unprivileged_pty(
    program: &str,
    args: &[&str],
    env: &BTreeMap<String, String>,
    workspace: &Path,
    pty: &GuestPty<'_>,
) -> std::io::Result<Child> {
    if std::process::id() != 1 {
        return Err(std::io::Error::other("guest_pid1_required"));
    }
    let fd = pty.slave.as_raw_fd();
    let cgroup_fd = pty.cgroup_procs.as_raw_fd();
    let pids_max = pty.pids_max;
    let mut command = Command::new(program);
    command
        .args(args)
        .env_clear()
        .envs(env)
        .current_dir(workspace)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // SAFETY: this pre-exec callback uses direct async-signal-safe syscalls only.
    // It clears supplementary groups and drops root before executing agent code.
    unsafe {
        command.pre_exec(move || {
            // A write of 0 enrolls this child before any uid-1000 code runs.
            if libc::write(cgroup_fd, b"0".as_ptr().cast(), 1) != 1
                || libc::setsid() == -1
                || libc::ioctl(fd, libc::TIOCSCTTY, 0) == -1
                || libc::setgroups(0, std::ptr::null()) == -1
                || libc::setgid(1000) == -1
                || libc::setuid(1000) == -1
                || libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == -1
            {
                return Err(std::io::Error::last_os_error());
            }
            let limits = libc::rlimit {
                rlim_cur: pids_max.into(),
                rlim_max: pids_max.into(),
            };
            if libc::setrlimit(libc::RLIMIT_NPROC, &limits) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            let core = libc::rlimit {
                rlim_cur: 0,
                rlim_max: 0,
            };
            if libc::setrlimit(libc::RLIMIT_CORE, &core) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            for target in [0, 1, 2] {
                if libc::dup2(fd, target) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            if fd > 2 {
                libc::close(fd);
            }
            Ok(())
        });
    }
    command.spawn()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guest_launchers_refuse_accidental_host_execution() {
        assert_ne!(std::process::id(), 1);
        let error = spawn_workspace_git(&["status"], Path::new("/"))
            .expect_err("the host must not execute guest Git");
        assert_eq!(error.to_string(), "guest_pid1_required");
        let (_master, slave) = crate::open_pty().unwrap();
        let membership = File::open("/dev/null").unwrap();
        let error = spawn_unprivileged_pty(
            "/bin/true",
            &[],
            &BTreeMap::new(),
            Path::new("/"),
            &GuestPty {
                slave: &slave,
                cgroup_procs: &membership,
                pids_max: 128,
            },
        )
        .expect_err("the host must not execute a guest profile");
        assert_eq!(error.to_string(), "guest_pid1_required");
    }
}
