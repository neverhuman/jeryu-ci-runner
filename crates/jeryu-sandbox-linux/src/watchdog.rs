//! Bounded pipe supervision and verified cleanup. Raw `Child` callers own only
//! a process group; descendants can leave that group. Complete-tree cleanup
//! uses the launch-owned cgroup supplied by `spawn_sandboxed_owned`, together
//! with execution custody that denies jobs cgroup migration/control access.

mod capture;
mod process;
pub(crate) mod termination;

use crate::launch::SupervisedChild;
use capture::Capture;
pub use capture::{CaptureOptions, DEFAULT_OUTPUT_LIMIT, MAX_OUTPUT_LIMIT};
use std::io;
use std::process::{Child, ExitStatus};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::thread;
use std::time::{Duration, Instant};
use termination::CgroupControl;

const CLEANUP_GRACE: Duration = Duration::from_secs(2);
const POLL: Duration = Duration::from_millis(10);

/// Cooperative cancellation wakes the supervisor on its next bounded sweep.
#[derive(Clone, Debug, Default)]
pub struct Cancellation(Arc<AtomicBool>);
impl Cancellation {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

#[derive(Debug, Default)]
pub struct WatchdogOptions {
    pub capture: CaptureOptions,
    pub cancellation: Cancellation,
}

/// What the cleanup proof covers. Group scope excludes escaped descendants.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TerminationScope {
    ProcessGroup,
    OwnedCgroup,
}

/// Captured prefixes and the actual terminal state. Output overflow is failure,
/// even if the executable managed to exit zero before the signal arrived.
#[derive(Debug)]
pub struct WatchdogOutcome {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub stdout_sha256: String,
    pub stderr_sha256: String,
    pub exit_code: Option<i32>,
    pub timed_out: bool,
    pub cancelled: bool,
    pub output_limit_exceeded: bool,
    pub termination_scope: TerminationScope,
    pub elapsed: Duration,
}

/// Compatibility entrypoint with bounded default capture and group-only scope.
/// The child must lead its own group, and this function must be its sole waiter.
pub fn run_with_watchdog(child: Child, timeout: Duration) -> io::Result<WatchdogOutcome> {
    run_with_watchdog_options(child, timeout, WatchdogOptions::default())
}

/// The caller should validate spools before spawning. Validation is repeated
/// here; rejection after spawn still terminates and reaps the owned child.
pub fn run_with_watchdog_options(
    child: Child,
    timeout: Duration,
    options: WatchdogOptions,
) -> io::Result<WatchdogOutcome> {
    supervise(child, None, timeout, options)
}

/// Supervise the exact child and cgroup returned by the owned launch path.
pub fn run_owned_with_watchdog(
    child: SupervisedChild,
    timeout: Duration,
    options: WatchdogOptions,
) -> io::Result<WatchdogOutcome> {
    supervise(child.child, child.cgroup, timeout, options)
}

struct Custody {
    child: Child,
    cgroup: Option<CgroupControl>,
    pid: i32,
    group: bool,
}

fn supervise(
    child: Child,
    cgroup: Option<CgroupControl>,
    timeout: Duration,
    options: WatchdogOptions,
) -> io::Result<WatchdogOutcome> {
    let started = Instant::now();
    let pid = i32::try_from(child.id())
        .map_err(|_| io::Error::other("invalid child PID; cleanup unresolved"))?;
    let mut custody = Custody {
        child,
        cgroup,
        pid,
        group: false,
    };
    let mut captures = None;
    let mut timed_out = false;
    let mut cancelled = false;
    let execution = (|| -> io::Result<()> {
        custody.group = process::is_group_leader(pid)?;
        if !custody.group {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "child must lead its own process group",
            ));
        }
        options.capture.validate()?;
        let CaptureOptions {
            max_bytes_per_stream,
            stdout_spool,
            stderr_spool,
        } = options.capture;
        let stdout = Capture::new(
            custody.child.stdout.take(),
            stdout_spool,
            max_bytes_per_stream,
        )?;
        let stderr = Capture::new(
            custody.child.stderr.take(),
            stderr_spool,
            max_bytes_per_stream,
        )?;
        captures = Some((stdout, stderr));
        loop {
            let (stdout, stderr) = captures.as_mut().expect("initialized capture");
            stdout.drain()?;
            stderr.drain()?;
            cancelled = options.cancellation.is_cancelled();
            timed_out = started.elapsed() >= timeout;
            if cancelled || timed_out || stdout.overflow || stderr.overflow || process::exited(pid)?
            {
                break;
            }
            thread::sleep(POLL.min(timeout.saturating_sub(started.elapsed())));
        }
        Ok(())
    })();
    // This runs for every fallible step after ownership transfer, including
    // descriptor admission and capture errors. It never waits without a bound.
    let cleanup = custody.finish(&mut captures);
    let status = match (execution, cleanup) {
        (Ok(()), Ok(status)) => status,
        (Err(error), Ok(_)) => {
            return Err(io::Error::other(format!(
                "{error}; child cleanup completed"
            )));
        }
        (Ok(()), Err(error)) => return Err(error),
        (Err(error), Err(cleanup)) => return Err(io::Error::other(format!("{error}; {cleanup}"))),
    };
    let (mut stdout, mut stderr) = captures.expect("successful execution initialized capture");
    let stdout_sha256 = stdout.finish()?;
    let stderr_sha256 = stderr.finish()?;
    Ok(WatchdogOutcome {
        output_limit_exceeded: stdout.overflow || stderr.overflow,
        stdout: stdout.bytes,
        stderr: stderr.bytes,
        stdout_sha256,
        stderr_sha256,
        exit_code: status.code(),
        timed_out,
        cancelled: cancelled || options.cancellation.is_cancelled(),
        termination_scope: if custody.cgroup.is_some() {
            TerminationScope::OwnedCgroup
        } else {
            TerminationScope::ProcessGroup
        },
        elapsed: started.elapsed(),
    })
}

impl Custody {
    fn finish(&mut self, captures: &mut Option<(Capture, Capture)>) -> io::Result<ExitStatus> {
        self.finish_with_signal(captures, process::kill)
            .map_err(|error| match &self.cgroup {
                Some(cgroup) => {
                    io::Error::other(format!("{error}; owned_cgroup={}", cgroup.label()))
                }
                None => error,
            })
    }

    fn finish_with_signal(
        &mut self,
        captures: &mut Option<(Capture, Capture)>,
        signal: impl FnOnce(i32, bool) -> io::Result<()>,
    ) -> io::Result<ExitStatus> {
        let started = Instant::now();
        let deadline = started + CLEANUP_GRACE;
        let mut failure = None;
        let mut capture_failed = false;
        if let Some(cgroup) = &mut self.cgroup
            && let Err(error) = cgroup.kill()
        {
            failure = Some(format!("cgroup kill failed: {error}"));
        }
        // Signal at most once, while the leader PID is still reserved. Even if
        // cgroup termination failed, attempt to stop the owned direct child.
        if let Err(error) = signal(self.pid, self.group) {
            failure.get_or_insert_with(|| format!("process kill failed: {error}"));
        }
        let mut status = None;
        loop {
            if let Some((stdout, stderr)) = captures.as_mut()
                && !capture_failed
                && let Err(error) = stdout.drain().and_then(|()| stderr.drain())
            {
                failure.get_or_insert_with(|| format!("output capture failed: {error}"));
                capture_failed = true;
            }
            let exited = if status.is_some() {
                Ok(true)
            } else {
                process::exited(self.pid)
            };
            let stopped = if let Some(cgroup) = &mut self.cgroup {
                cgroup.empty()
            } else if self.group {
                process::group_stopped(self.pid, deadline)
            } else {
                exited
                    .as_ref()
                    .map(|v| *v)
                    .map_err(|e| io::Error::other(e.to_string()))
            };
            match (exited, stopped) {
                (Ok(true), Ok(true)) => {
                    if status.is_none() {
                        match self.child.try_wait() {
                            Ok(observed) => status = observed,
                            Err(error) => {
                                failure
                                    .get_or_insert_with(|| format!("child reap failed: {error}"));
                            }
                        }
                    }
                    let drained = capture_failed
                        || captures
                            .as_ref()
                            .is_none_or(|(out, err)| out.eof && err.eof);
                    if let Some(status) = status.filter(|_| drained) {
                        if let Some(cgroup) = &mut self.cgroup
                            && let Err(error) = cgroup.cleanup()
                        {
                            failure.get_or_insert_with(|| {
                                format!("cgroup cleanup unresolved: {error}")
                            });
                        }
                        return match failure {
                            Some(error) => Err(io::Error::other(error)),
                            None => Ok(status),
                        };
                    }
                }
                (Err(error), _) | (_, Err(error)) => {
                    failure
                        .get_or_insert_with(|| format!("termination verification failed: {error}"));
                }
                _ => {}
            }
            if started.elapsed() >= CLEANUP_GRACE {
                // Reap an exited leader even if another resource is unresolved.
                // No numeric PID/PGID signals occur after this point.
                let reaped = status.is_some()
                    || self
                        .child
                        .try_wait()
                        .map_err(|error| {
                            io::Error::other(format!(
                                "cleanup unresolved; child reap failed: {error}"
                            ))
                        })?
                        .is_some();
                return Err(io::Error::other(format!(
                    "cleanup unresolved after {}ms (leader_reaped={reaped}): {}",
                    CLEANUP_GRACE.as_millis(),
                    failure.unwrap_or_else(|| "live members or output pipes remain".into())
                )));
            }
            thread::sleep(POLL);
        }
    }
}

#[cfg(test)]
mod tests;
