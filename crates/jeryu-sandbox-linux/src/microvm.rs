//! Narrow privileged launcher primitive. Trusted runtime admission and resource
//! validation occur before this function; callers cannot supply a shell command.
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};

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
    let mut command = Command::new(jailer);
    command
        .args(args)
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // SAFETY: the child callback performs only direct syscalls before exec.
    // A fresh network namespace contains no configured interfaces or host ports.
    unsafe {
        command.pre_exec(|| {
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
