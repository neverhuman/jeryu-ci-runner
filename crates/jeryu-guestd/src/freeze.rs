//! Kill every guest-user descendant, flush, and remount the workspace read-only.
//! Credential home and /tmp remain tmpfs and never enter the retained disk.
use nix::{
    mount::{MsFlags, mount},
    sys::signal::{Signal, kill},
    unistd::{Pid, sync},
};
use std::{
    fs,
    time::{Duration, Instant},
};
pub fn workspace(
    reaper: &crate::reaper::Reaper,
    ready: &Option<jeryu_runner_protocol::wire::v2::WorkspaceReady>,
    generation: u64,
) -> std::io::Result<Option<jeryu_runner_protocol::wire::v2::WorkspaceReady>> {
    if std::process::id() != 1 {
        return Err(failed());
    }
    quiesce_users()?;
    let receipt = crate::workspace::frozen_receipt(ready, reaper)?;
    if receipt
        .as_ref()
        .is_some_and(|r| r.sync_state == jeryu_runner_protocol::wire::v2::WorkspaceSyncState::Ready)
    {
        crate::workspace::checkpoint_ref(generation, reaper)?;
    }
    // Git filters or merge drivers can start descendants during checkpointing.
    quiesce_users()?;
    sync();
    mount(
        None::<&str>,
        "/workspace",
        None::<&str>,
        MsFlags::MS_REMOUNT | MsFlags::MS_RDONLY | MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
        None::<&str>,
    )
    .map_err(|_| failed())?;
    Ok(receipt)
}
pub fn quiesce_users() -> std::io::Result<()> {
    if std::process::id() != 1 {
        return Err(failed());
    }
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        let mut live = false;
        for entry in fs::read_dir("/proc")? {
            let entry = entry?;
            let Some(pid) = entry
                .file_name()
                .to_str()
                .and_then(|name| name.parse::<i32>().ok())
                .filter(|pid| *pid > 1)
            else {
                continue;
            };
            let Ok(status) = fs::read_to_string(entry.path().join("status")) else {
                continue;
            };
            if !status.lines().any(|line| {
                line.starts_with("Uid:") && line.split_whitespace().skip(1).all(|id| id == "1000")
            }) || status
                .lines()
                .any(|line| line.starts_with("State:") && line.contains("Z (zombie)"))
            {
                continue;
            }
            let _ = kill(Pid::from_raw(pid), Signal::SIGKILL);
            live = true;
        }
        if !live {
            break;
        }
        if Instant::now() >= deadline {
            return Err(failed());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    Ok(())
}
fn failed() -> std::io::Error {
    std::io::Error::other("guest_checkpoint_flush_failed")
}
