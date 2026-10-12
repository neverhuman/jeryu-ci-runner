//! Narrow privileged launcher primitive. Trusted runtime admission and resource
//! validation occur before this function; callers cannot supply a shell command.
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};

mod executables;
pub use executables::{
    GuardianChild, inherited_executables, sealed_executable, spawn_guarded_jailer_files,
    spawn_guardian_files,
};

pub fn disable_core_dumps() -> std::io::Result<()> {
    let limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: setrlimit reads the valid initialized limit and retains no pointer.
    if unsafe { libc::setrlimit(libc::RLIMIT_CORE, &limit) } == -1 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

pub fn spawn_jailer(jailer: &Path, args: &[String]) -> std::io::Result<Child> {
    spawn(jailer, args, None)
}

pub fn spawn_guarded_jailer(
    jailer: &Path,
    args: &[String],
    membership: &Path,
) -> std::io::Result<Child> {
    spawn(jailer, args, Some(membership))
}

fn spawn(jailer: &Path, args: &[String], membership: Option<&Path>) -> std::io::Result<Child> {
    let mut command = Command::new(jailer);
    command
        .args(args)
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let membership = membership
        .map(|path| std::fs::OpenOptions::new().write(true).open(path))
        .transpose()?;
    // SAFETY: the child callback performs only direct syscalls before exec.
    // A fresh network namespace contains no configured interfaces or host ports.
    unsafe {
        command.pre_exec(move || {
            if let Some(file) = &membership {
                use std::os::fd::AsRawFd;
                if libc::write(file.as_raw_fd(), b"0".as_ptr().cast(), 1) != 1 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            if libc::unshare(libc::CLONE_NEWNET) == -1 || libc::setsid() == -1 {
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

/// Trusted self-reexec; the inherited stdin is a private socket, not user input.
pub fn spawn_guardian(
    executable: &Path,
    channel: std::os::fd::OwnedFd,
    fence: std::fs::File,
) -> std::io::Result<Child> {
    let mut command = Command::new(executable);
    command
        .arg("--vm-guardian")
        .env_clear()
        .stdin(Stdio::from(channel))
        .stdout(Stdio::from(fence))
        .stderr(Stdio::null());
    // SAFETY: only direct syscalls occur between fork and exec.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command.spawn()
}
