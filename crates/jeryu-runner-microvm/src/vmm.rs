//! PID reuse cannot authorize a host signal. Recovery checks journal identity,
//! boot, start time, UID, jail root and executable, then holds a kernel pidfd.
//! Jailer 1.17 PID-file source: https://github.com/firecracker-microvm/firecracker/blob/v1.17.0/src/jailer/src/env.rs
use crate::{artifacts::sha256_reader, journal::ResourceRecord};
use jeryu_runner_core::{RunnerError, RunnerResult};
use rustix::{
    event::{PollFd, PollFlags, poll},
    process::{Pid, PidfdFlags, Signal, pidfd_open, pidfd_send_signal},
};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VmmIdentity {
    pub host_pid: u32,
    pub start_ticks: u64,
    pub boot_id: String,
}
pub(crate) struct VmmGuard {
    fd: rustix::fd::OwnedFd,
    pub identity: VmmIdentity,
}
impl VmmGuard {
    pub fn recover(record: &ResourceRecord, root: &Path) -> RunnerResult<Option<Self>> {
        let boot_id = fs::read_to_string("/proc/sys/kernel/random/boot_id")?
            .trim()
            .to_owned();
        if record
            .vmm
            .as_ref()
            .is_some_and(|vmm| vmm.boot_id != boot_id)
        {
            return Ok(None);
        }
        let path = root.join("firecracker.pid");
        let mut file = match OpenOptions::new()
            .read(true)
            .custom_flags(nix::libc::O_NOFOLLOW)
            .open(path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound && record.vmm.is_none() => {
                return Ok(None);
            }
            Err(error) => return Err(error.into()),
        };
        let meta = file.metadata()?;
        if !meta.is_file()
            || meta.uid() != 0
            || meta.nlink() != 1
            || meta.mode() & 0o022 != 0
            || meta.len() > 32
        {
            return Err(failed("microvm_pid_custody_denied"));
        }
        let mut text = String::new();
        file.read_to_string(&mut text)?;
        let raw: u32 = text
            .trim()
            .parse()
            .map_err(|_| failed("microvm_pid_invalid"))?;
        let pid = Pid::from_raw(i32::try_from(raw).map_err(|_| failed("microvm_pid_invalid"))?)
            .filter(|_| raw > 1)
            .ok_or_else(|| failed("microvm_pid_invalid"))?;
        let process = Path::new("/proc").join(raw.to_string());
        let before = match process_state(&process)? {
            Some(state) => state,
            None => return Ok(None),
        };
        let identity = VmmIdentity {
            host_pid: raw,
            start_ticks: before,
            boot_id,
        };
        if record
            .vmm
            .as_ref()
            .is_some_and(|expected| expected != &identity)
        {
            // The old process exited; this PID now belongs to another process.
            return Ok(None);
        }
        let fd = match pidfd_open(pid, PidfdFlags::empty()) {
            Ok(fd) => fd,
            Err(rustix::io::Errno::SRCH) => return Ok(None),
            Err(_) => return Err(failed("microvm_pidfd_unavailable")),
        };
        let uid_ok = fs::read_to_string(process.join("status"))?
            .lines()
            .find_map(|line| line.strip_prefix("Uid:"))
            .is_some_and(|ids| {
                ids.split_whitespace().count() == 4
                    && ids
                        .split_whitespace()
                        .all(|id| id.parse::<u32>() == Ok(record.uid))
            });
        if !uid_ok {
            return Err(failed("microvm_process_uid_denied"));
        }
        // pivot_root may display '/' in the other mount namespace. Compare the
        // underlying inode, not the rendering of the /proc symlink.
        let actual_root = fs::metadata(process.join("root"))?;
        let expected_root = fs::metadata(root)?;
        if (actual_root.dev(), actual_root.ino()) != (expected_root.dev(), expected_root.ino()) {
            return Err(failed("microvm_process_root_denied"));
        }
        if sha256_reader(&mut File::open(process.join("exe"))?)? != record.firecracker_digest {
            return Err(failed("microvm_process_executable_denied"));
        }
        if process_state(&process)? != Some(before) {
            return Err(failed("microvm_process_start_time_denied"));
        }
        Ok(Some(Self { fd, identity }))
    }
    pub fn terminate(&self) -> RunnerResult<()> {
        match pidfd_send_signal(&self.fd, Signal::KILL) {
            Ok(()) | Err(rustix::io::Errno::SRCH) => Ok(()),
            Err(_) => Err(failed("microvm_process_termination_failed")),
        }
    }
    pub fn wait_dead(&self) -> RunnerResult<()> {
        let mut events = [PollFd::new(&self.fd, PollFlags::IN)];
        let timeout = rustix::event::Timespec {
            tv_sec: 5,
            tv_nsec: 0,
        };
        poll(&mut events, Some(&timeout))
            .map_err(|_| failed("microvm_process_termination_failed"))?;
        if events[0].revents().contains(PollFlags::IN) {
            Ok(())
        } else {
            Err(failed("microvm_cleanup_timeout"))
        }
    }
}

fn process_state(process: &Path) -> RunnerResult<Option<u64>> {
    let stat = match fs::read_to_string(process.join("stat")) {
        Ok(stat) => stat,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    parse_stat(&stat)
}
fn parse_stat(stat: &str) -> RunnerResult<Option<u64>> {
    let fields: Vec<_> = stat
        .rsplit_once(") ")
        .ok_or_else(|| failed("microvm_process_stat_invalid"))?
        .1
        .split_whitespace()
        .collect();
    if matches!(fields.first(), Some(&"Z" | &"X")) {
        return Ok(None);
    }
    let ticks = fields
        .get(19)
        .and_then(|field| field.parse::<u64>().ok())
        .filter(|ticks| *ticks != 0)
        .ok_or_else(|| failed("microvm_process_stat_invalid"))?;
    Ok(Some(ticks))
}
fn failed(code: &'static str) -> RunnerError {
    RunnerError::new(code, "VM process recovery rejected")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn proc_start_time_handles_nested_parentheses_and_exited_processes() {
        let fields = format!("S {} 321 0", vec!["0"; 18].join(" "));
        assert_eq!(
            parse_stat(&format!("123 (fire)cracker) {fields}")).unwrap(),
            Some(321)
        );
        assert_eq!(parse_stat("123 (firecracker) Z").unwrap(), None);
        assert!(parse_stat("123 (firecracker) S").is_err());
    }
}
