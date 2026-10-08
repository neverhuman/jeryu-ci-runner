use nix::{
    mount::{MsFlags, mount},
    sys::stat::{Mode, SFlag, makedev, mknod},
    unistd::{Gid, Uid, chown},
};
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    path::Path,
    process::{Command, Stdio},
};

pub fn initialize(restored: bool) -> std::io::Result<()> {
    if std::process::id() != 1 {
        return Err(std::io::Error::other("guest_pid1_required"));
    }
    mount(
        Some("proc"),
        "/proc",
        Some("proc"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
        None::<&str>,
    )
    .map_err(|_| std::io::Error::other("guest_proc_mount_failed"))?;
    mount(
        Some("sysfs"),
        "/sys",
        Some("sysfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
        None::<&str>,
    )
    .map_err(|_| std::io::Error::other("guest_sys_mount_failed"))?;
    // The trusted launcher establishes Firecracker identity through signed
    // artifact admission. This PID-1 bootstrap is called only after binding the
    // dedicated virtio-vsock host peer. Supported kernels need not expose SMBIOS.
    mount(
        Some("tmpfs"),
        "/dev",
        Some("tmpfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NOEXEC,
        Some("size=4m,mode=0755"),
    )
    .map_err(|_| std::io::Error::other("guest_dev_mount_failed"))?;
    for (name, major, minor) in [
        ("null", 1, 3),
        ("zero", 1, 5),
        ("random", 1, 8),
        ("urandom", 1, 9),
        ("tty", 5, 0),
    ] {
        let path = Path::new("/dev").join(name);
        mknod(
            &path,
            SFlag::S_IFCHR,
            Mode::from_bits_truncate(0o666),
            makedev(major, minor),
        )
        .map_err(|_| std::io::Error::other("guest_device_failed"))?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o666))
            .map_err(|_| std::io::Error::other("guest_device_failed"))?;
    }
    let device = fs::read_to_string("/sys/class/block/vdb/dev")
        .map_err(|_| std::io::Error::other("guest_workspace_device_missing"))?;
    let (major, minor) = device
        .trim()
        .split_once(':')
        .and_then(|(major, minor)| Some((major.parse::<u64>().ok()?, minor.parse::<u64>().ok()?)))
        .filter(|(major, minor)| *major < 4096 && *minor < (1 << 20))
        .ok_or_else(|| std::io::Error::other("guest_workspace_device_invalid"))?;
    mknod(
        "/dev/vdb",
        SFlag::S_IFBLK,
        Mode::from_bits_truncate(0o600),
        makedev(major, minor),
    )
    .map_err(|_| std::io::Error::other("guest_workspace_device_failed"))?;
    fs::create_dir_all("/dev/pts").map_err(|_| std::io::Error::other("guest_devpts_failed"))?;
    mount(
        Some("devpts"),
        "/dev/pts",
        Some("devpts"),
        MsFlags::MS_NOSUID | MsFlags::MS_NOEXEC,
        Some("mode=0620,ptmxmode=0666"),
    )
    .map_err(|_| std::io::Error::other("guest_pty_mount_failed"))?;
    symlink("pts/ptmx", "/dev/ptmx")
        .map_err(|_| std::io::Error::other("guest_pty_device_failed"))?;
    for directory in ["/run", "/tmp"] {
        mount(
            Some("tmpfs"),
            directory,
            Some("tmpfs"),
            MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
            Some("size=64m,mode=1777"),
        )
        .map_err(|_| std::io::Error::other("guest_tmpfs_mount_failed"))?;
    }
    if !restored {
        let status = Command::new("/sbin/mkfs.ext4")
            .args(["-q", "-F", "/dev/vdb"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|_| std::io::Error::other("guest_workspace_formatter_unavailable"))?;
        if !status.success() {
            return Err(std::io::Error::other("guest_workspace_format_failed"));
        }
    }
    mount(
        Some("/dev/vdb"),
        "/workspace",
        Some("ext4"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
        None::<&str>,
    )
    .map_err(|_| std::io::Error::other("guest_workspace_mount_failed"))?;
    fs::create_dir("/run/agent-home").map_err(|_| std::io::Error::other("guest_home_failed"))?;
    let paths: &[&str] = if restored {
        &["/run/agent-home"]
    } else {
        &["/workspace", "/run/agent-home"]
    };
    for path in paths {
        chown(
            Path::new(path),
            Some(Uid::from_raw(1000)),
            Some(Gid::from_raw(1000)),
        )
        .map_err(|_| std::io::Error::other("guest_identity_failed"))?;
    }
    Ok(())
}
