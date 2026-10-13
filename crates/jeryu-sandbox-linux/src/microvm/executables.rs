//! Descriptor handoff and a private, read-only Firecracker execution view.
use std::{
    ffi::CString,
    fs::File,
    io::{self, Write},
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::{fs::FileExt, process::CommandExt},
    },
    path::Path,
    process::{Child, Command, Stdio},
};

pub struct GuardianChild {
    pub child: Child,
    pub descriptors: [i32; 2],
}

fn duplicate(file: &File, minimum: i32) -> io::Result<File> {
    // SAFETY: fcntl borrows a live fd and returns a new, uniquely owned fd.
    let fd = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_DUPFD_CLOEXEC, minimum) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a successful F_DUPFD_CLOEXEC returned this owned descriptor.
    Ok(unsafe { File::from_raw_fd(fd) })
}

/// Only these two duplicates cross self-reexec. The parent remains CLOEXEC;
/// the child clears that flag before exec, and the guardian closes originals.
pub fn spawn_guardian_files(
    executable: &File,
    channel: OwnedFd,
    fence: File,
    jailer: &File,
    firecracker: &File,
) -> io::Result<GuardianChild> {
    let jailer = duplicate(jailer, 64)?;
    let firecracker = duplicate(firecracker, 64)?;
    let descriptors = [jailer.as_raw_fd(), firecracker.as_raw_fd()];
    // Reserved duplicates exist before Command allocates its exec error pipe.
    let mut command = Command::new(format!("/proc/self/fd/{}", executable.as_raw_fd()));
    command
        .arg("--vm-guardian")
        .env_clear()
        .stdin(Stdio::from(channel))
        .stdout(Stdio::from(fence))
        .stderr(Stdio::null());
    // SAFETY: the child callback performs only direct syscalls with live fds.
    unsafe {
        command.pre_exec(move || {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            for fd in descriptors {
                if libc::fcntl(fd, libc::F_SETFD, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
    let child = command.spawn()?;
    // Keep both parent duplicates alive through fork/exec; then close them.
    drop((jailer, firecracker));
    Ok(GuardianChild { child, descriptors })
}

/// Private self-reexec entrypoint only; duplicate before closing inherited fds.
pub fn inherited_executables(descriptors: [i32; 2]) -> io::Result<[File; 2]> {
    if descriptors[0] < 64 || descriptors[1] < 64 || descriptors[0] == descriptors[1] {
        return Err(io::Error::other("invalid guardian executable descriptors"));
    }
    let mut files = Vec::with_capacity(2);
    for fd in descriptors {
        // SAFETY: libc accepts any integer and reports EBADF for a closed fd.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        // SAFETY: F_GETFL accepts an integer fd and returns EBADF on failure.
        let access = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0
            || flags & libc::FD_CLOEXEC != 0
            || access < 0
            || access & libc::O_ACCMODE != libc::O_RDONLY
        {
            return Err(io::Error::other("missing inherited executable descriptor"));
        }
        // SAFETY: dup creates a new owned descriptor without borrowing raw fd.
        let copy = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3) };
        if copy < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: copy is newly allocated and owned by this function.
        files.push(unsafe { File::from_raw_fd(copy) });
    }
    for fd in descriptors {
        // SAFETY: originals belong solely to the private guardian entrypoint.
        if unsafe { libc::close(fd) } == -1 {
            return Err(io::Error::last_os_error());
        }
    }
    files
        .try_into()
        .map_err(|_| io::Error::other("executable descriptor count"))
}

/// Snapshot a bounded descriptor without changing its seek position. Seals
/// prevent content changes through any descriptor, including a writable alias.
pub fn sealed_executable(source: &File, maximum_bytes: u64) -> io::Result<File> {
    let length = source.metadata()?.len();
    if length == 0 || length > maximum_bytes {
        return Err(io::Error::other("executable snapshot size denied"));
    }
    // SAFETY: the constant name is NUL terminated and flags are documented.
    let fd = unsafe {
        libc::memfd_create(
            c"firecracker".as_ptr(),
            libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: memfd_create returned a new uniquely owned fd.
    let mut snapshot = unsafe { File::from_raw_fd(fd) };
    let mut bytes = [0u8; 65536];
    let mut offset = 0;
    while offset < length {
        let count = source.read_at(
            &mut bytes[..((length - offset).min(65536) as usize)],
            offset,
        )?;
        if count == 0 {
            return Err(io::Error::other("executable snapshot truncated"));
        }
        snapshot.write_all(&bytes[..count])?;
        offset += count as u64;
    }
    if source.read_at(&mut bytes[..1], offset)? != 0 {
        return Err(io::Error::other("executable snapshot grew"));
    }
    // SAFETY: these syscalls borrow the live snapshot fd and retain no pointers.
    unsafe {
        if libc::fchmod(fd, 0o555) == -1
            || libc::fcntl(
                fd,
                libc::F_ADD_SEALS,
                libc::F_SEAL_WRITE | libc::F_SEAL_GROW | libc::F_SEAL_SHRINK | libc::F_SEAL_SEAL,
            ) == -1
        {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(snapshot)
}

/// Jailer canonicalizes its executable path before copying it. Give it an
/// immutable mount in a fresh private namespace, preserving basename firecracker.
/// No inherited artifact fd reaches Jailer or the unprivileged VMM after exec.
pub fn spawn_guarded_jailer_files(
    jailer: &File,
    firecracker: &File,
    args: &[String],
    membership: &Path,
) -> io::Result<Child> {
    let required_seals =
        libc::F_SEAL_WRITE | libc::F_SEAL_GROW | libc::F_SEAL_SHRINK | libc::F_SEAL_SEAL;
    // SAFETY: fcntl borrows a live descriptor and writes no userspace memory.
    let seals = unsafe { libc::fcntl(firecracker.as_raw_fd(), libc::F_GET_SEALS) };
    if seals < 0 || seals & required_seals != required_seals {
        return Err(io::Error::other("unsealed Firecracker snapshot denied"));
    }
    let source = CString::new(format!("/proc/self/fd/{}", firecracker.as_raw_fd()))
        .map_err(|_| io::Error::other("invalid executable descriptor"))?;
    let membership = std::fs::OpenOptions::new().write(true).open(membership)?;
    let mut command = Command::new(format!("/proc/self/fd/{}", jailer.as_raw_fd()));
    command
        .args(args)
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // SAFETY: only direct syscalls with preallocated constants and live fds.
    unsafe {
        command.pre_exec(move || {
            if libc::write(membership.as_raw_fd(), b"0".as_ptr().cast(), 1) != 1
                || libc::unshare(libc::CLONE_NEWNET | libc::CLONE_NEWNS) == -1
                || libc::setsid() == -1
            {
                return Err(io::Error::last_os_error());
            }
            if libc::mount(
                std::ptr::null(),
                c"/".as_ptr(),
                std::ptr::null(),
                libc::MS_REC | libc::MS_PRIVATE,
                std::ptr::null(),
            ) == -1
                || libc::mount(
                    c"tmpfs".as_ptr(),
                    c"/tmp".as_ptr(),
                    c"tmpfs".as_ptr(),
                    libc::MS_NOSUID | libc::MS_NODEV,
                    c"mode=0700,size=1m".as_ptr().cast(),
                ) == -1
                || libc::mkdir(c"/tmp/jeryu-runtime-exec".as_ptr(), 0o700) == -1
            {
                return Err(io::Error::last_os_error());
            }
            let target = c"/tmp/jeryu-runtime-exec/firecracker";
            let fd = libc::open(
                target.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o555,
            );
            if fd == -1 {
                return Err(io::Error::last_os_error());
            }
            if libc::close(fd) == -1
                || libc::mount(
                    source.as_ptr(),
                    target.as_ptr(),
                    std::ptr::null(),
                    libc::MS_BIND,
                    std::ptr::null(),
                ) == -1
                || libc::mount(
                    std::ptr::null(),
                    target.as_ptr(),
                    std::ptr::null(),
                    libc::MS_BIND
                        | libc::MS_REMOUNT
                        | libc::MS_RDONLY
                        | libc::MS_NOSUID
                        | libc::MS_NODEV,
                    std::ptr::null(),
                ) == -1
                || libc::mount(
                    std::ptr::null(),
                    c"/tmp".as_ptr(),
                    std::ptr::null(),
                    libc::MS_REMOUNT | libc::MS_RDONLY | libc::MS_NOSUID | libc::MS_NODEV,
                    std::ptr::null(),
                ) == -1
            {
                return Err(io::Error::last_os_error());
            }
            let core = libc::rlimit {
                rlim_cur: 0,
                rlim_max: 0,
            };
            if libc::setrlimit(libc::RLIMIT_CORE, &core) == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command.spawn()
}

#[cfg(test)]
mod tests;
