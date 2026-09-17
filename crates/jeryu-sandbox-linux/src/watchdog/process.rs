//! Process-group fallback. The supervisor must be the child's only waiter.

use std::fs::{self, File};
use std::io::{self, Read};
use std::time::Instant;

/// Observe exit without reaping. Keeping the leader as a child reserves its PID
/// until the final group signal; we never signal a group after reaping it.
pub(super) fn exited(pid: i32) -> io::Result<bool> {
    use nix::sys::wait::{Id, WaitPidFlag, WaitStatus, waitid};
    let flags = WaitPidFlag::WEXITED | WaitPidFlag::WNOHANG | WaitPidFlag::WNOWAIT;
    match waitid(Id::Pid(nix::unistd::Pid::from_raw(pid)), flags) {
        Ok(WaitStatus::StillAlive) => Ok(false),
        Ok(status) => Ok(status.pid() == Some(nix::unistd::Pid::from_raw(pid))),
        Err(errno) => Err(io::Error::from(errno)),
    }
}

pub(super) fn is_group_leader(pid: i32) -> io::Result<bool> {
    // First establish the unreaped direct-child relationship. ECHILD is never
    // treated as permission to signal a potentially reused numeric PID.
    exited(pid)?;
    // SAFETY: getpgid only observes process metadata.
    let group = unsafe { libc::getpgid(pid) };
    if group == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(group == pid)
}

pub(super) fn kill(pid: i32, group: bool) -> io::Result<()> {
    exited(pid)?;
    // SAFETY: the sole waiter has not reaped this child; its PID is reserved.
    let result = unsafe { libc::kill(if group { -pid } else { pid }, libc::SIGKILL) };
    if result == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        Ok(())
    } else {
        Err(error)
    }
}

/// Prove that the group has no executing members. Zombies have already exited
/// and cannot retain pipes or run job code; only their own parent can reap them.
/// This cannot see or contain descendants that left the process group.
pub(super) fn group_stopped(group: i32, deadline: Instant) -> io::Result<bool> {
    check_deadline(deadline)?;
    for entry in fs::read_dir("/proc")? {
        check_deadline(deadline)?;
        let entry = entry?;
        if !entry
            .file_name()
            .as_encoded_bytes()
            .iter()
            .all(u8::is_ascii_digit)
        {
            continue;
        }
        let mut bytes = Vec::new();
        let read = File::open(entry.path().join("stat"))
            .and_then(|file| file.take(8193).read_to_end(&mut bytes));
        if let Err(error) = read {
            if matches!(error.raw_os_error(), Some(libc::ENOENT | libc::ESRCH)) {
                continue;
            }
            return Err(error);
        }
        if bytes.len() > 8192 {
            return Err(io::Error::other("oversized process stat"));
        }
        let (state, observed_group) = parse_stat(&bytes)?;
        if observed_group == group && !matches!(state, b'Z' | b'X' | b'x') {
            return Ok(false);
        }
    }
    Ok(true)
}

fn check_deadline(deadline: Instant) -> io::Result<()> {
    if Instant::now() >= deadline {
        return Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "process group observation exceeded cleanup deadline",
        ));
    }
    Ok(())
}

fn parse_stat(bytes: &[u8]) -> io::Result<(u8, i32)> {
    // comm is arbitrary bytes and may itself contain spaces or closing parens.
    let end = bytes
        .iter()
        .rposition(|b| *b == b')')
        .ok_or_else(|| io::Error::other("invalid process stat"))?;
    let mut fields = bytes[end + 1..]
        .split(|b| b.is_ascii_whitespace())
        .filter(|f| !f.is_empty());
    let state = fields
        .next()
        .filter(|f| f.len() == 1)
        .ok_or_else(|| io::Error::other("missing process state"))?[0];
    let _parent = fields
        .next()
        .ok_or_else(|| io::Error::other("missing process parent"))?;
    let group = fields
        .next()
        .ok_or_else(|| io::Error::other("missing process group"))?;
    let group = std::str::from_utf8(group)
        .map_err(io::Error::other)?
        .parse()
        .map_err(io::Error::other)?;
    Ok((state, group))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expired_group_observation_refuses_to_start_a_proc_sweep() {
        let error = group_stopped(1, Instant::now()).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
    }

    #[test]
    fn stat_parser_handles_delimiters_in_names() {
        assert_eq!(
            parse_stat(b"15 (odd ) name) Z 1 15 15 0").unwrap(),
            (b'Z', 15)
        );
        assert!(parse_stat(b"15 (name) S 1 nope").is_err());
    }
}
