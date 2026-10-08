//! Guest root owns channel groups. setsid, backgrounding and orphan adoption do
//! not move a process out of its cgroup. The uid-1000 agent cannot migrate itself.
use nix::mount::{MsFlags, mount};
use std::{
    fs::{self, File, OpenOptions},
    os::unix::fs::OpenOptionsExt,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant},
};
static NEXT: AtomicU64 = AtomicU64::new(1);
const ROOT: &str = "/sys/fs/cgroup/jeryu";

pub fn initialize() -> std::io::Result<()> {
    if std::process::id() != 1 {
        return Err(failed());
    }
    mount(
        Some("cgroup2"),
        "/sys/fs/cgroup",
        Some("cgroup2"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
        None::<&str>,
    )?;
    fs::write("/sys/fs/cgroup/cgroup.subtree_control", "+pids")?;
    fs::create_dir(ROOT)?;
    fs::write(format!("{ROOT}/cgroup.subtree_control"), "+pids")?;
    Ok(())
}

pub struct Group {
    root: PathBuf,
}
impl Group {
    pub fn create(pids_max: u32) -> std::io::Result<Self> {
        if std::process::id() != 1 || !(16..=4096).contains(&pids_max) {
            return Err(failed());
        }
        let root =
            PathBuf::from(ROOT).join(format!("channel-{}", NEXT.fetch_add(1, Ordering::Relaxed)));
        fs::create_dir(&root)?;
        let group = Self { root };
        fs::write(group.root.join("pids.max"), pids_max.to_string())?;
        // No uid/gid delegation: only PID 1 can write membership or kill.
        Ok(group)
    }
    pub fn membership(&self) -> std::io::Result<File> {
        OpenOptions::new()
            .write(true)
            .custom_flags(nix::libc::O_CLOEXEC | nix::libc::O_NOFOLLOW)
            .open(self.root.join("cgroup.procs"))
    }
    pub fn kill(&self) -> std::io::Result<()> {
        fs::write(self.root.join("cgroup.kill"), "1")?;
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            if fs::read_to_string(self.root.join("cgroup.events"))?
                .lines()
                .any(|line| line == "populated 0")
            {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(failed());
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
impl Drop for Group {
    fn drop(&mut self) {
        if self.kill().is_ok() {
            let _ = fs::remove_dir(&self.root);
        }
    }
}
fn failed() -> std::io::Error {
    std::io::Error::other("guest_channel_group_failed")
}
