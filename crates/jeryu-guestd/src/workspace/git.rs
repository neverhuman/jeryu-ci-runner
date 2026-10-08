//! Bounded guest-only Git. Stderr text is discarded; only safe metadata leaves.
use crate::reaper::Reaper;
use jeryu_runner_protocol::wire::v2::GitLimits;
use jeryu_sandbox_linux::guest::spawn_workspace_git;
use nix::{
    fcntl::{FcntlArg, OFlag, fcntl},
    sys::signal::{Signal, killpg},
    unistd::Pid,
};
use std::{
    io::Read,
    path::Path,
    sync::OnceLock,
    time::{Duration, Instant},
};
static LIMITS: OnceLock<GitLimits> = OnceLock::new();

pub fn configure(limits: GitLimits) -> std::io::Result<()> {
    limits
        .validate()
        .map_err(|_| failed("guest_git_limits_invalid"))?;
    LIMITS
        .set(limits)
        .map_err(|_| failed("guest_git_limits_rebound"))
}
pub fn diagnostic(error: &std::io::Error) -> Option<String> {
    error
        .get_ref()?
        .downcast_ref::<Diagnostic>()
        .map(ToString::to_string)
}
pub fn run(workspace: &Path, args: &[&str]) -> std::io::Result<String> {
    execute(workspace, args, None)
}
pub fn with_reaper(workspace: &Path, args: &[&str], reaper: &Reaper) -> std::io::Result<String> {
    execute(workspace, args, Some(reaper))
}
fn execute(workspace: &Path, args: &[&str], reaper: Option<&Reaper>) -> std::io::Result<String> {
    let limits = LIMITS.get().copied().unwrap_or_default();
    let mut diagnostic = Diagnostic::new(args.first().copied().unwrap_or("other"));
    let mut fixed_args = vec!["-c", "safe.directory=/workspace/repo"];
    fixed_args.extend_from_slice(args);
    let mut output = None;
    let mut stderr = None;
    let mut child = None;
    let pid = if let Some(reaper) = reaper {
        reaper.spawn(|| {
            let mut process = spawn_workspace_git(&fixed_args, workspace)?;
            output = process.stdout.take();
            stderr = process.stderr.take();
            Ok(process)
        })?
    } else {
        let mut process = spawn_workspace_git(&fixed_args, workspace)?;
        let pid =
            Pid::from_raw(i32::try_from(process.id()).map_err(|_| failed("guest_git_failed"))?);
        output = process.stdout.take();
        stderr = process.stderr.take();
        child = Some(process);
        pid
    };
    let result = (|| {
        let mut output = output.ok_or_else(|| failed("guest_git_unavailable"))?;
        let mut stderr = stderr.ok_or_else(|| failed("guest_git_unavailable"))?;
        for fd in [
            &output as &dyn std::os::fd::AsFd,
            &stderr as &dyn std::os::fd::AsFd,
        ] {
            fcntl(fd, FcntlArg::F_SETFL(OFlag::O_NONBLOCK))
                .map_err(|_| failed("guest_git_failed"))?;
        }
        let deadline = Instant::now() + Duration::from_secs(limits.timeout_seconds.into());
        let mut bytes = Vec::new();
        loop {
            drain_stdout(&mut output, &mut bytes, limits.stdout_bytes as usize)?;
            drain_stderr(
                &mut stderr,
                &mut diagnostic.stderr_bytes,
                limits.stderr_bytes as usize,
            )?;
            diagnostic.stdout_bytes = bytes.len();
            if bytes.len() > limits.stdout_bytes as usize
                || diagnostic.stderr_bytes > limits.stderr_bytes as usize
                || Instant::now() >= deadline
            {
                diagnostic.code = "guest_git_limit";
                diagnostic.truncated = diagnostic.stderr_bytes > limits.stderr_bytes as usize;
                return Err(std::io::Error::other(diagnostic.clone()));
            }
            let status = if let Some(reaper) = reaper {
                reaper.result(pid)
            } else {
                child
                    .as_mut()
                    .ok_or_else(|| failed("guest_git_failed"))?
                    .try_wait()?
                    .map(|s| s.code())
            };
            if let Some(code) = status {
                drain_stdout(&mut output, &mut bytes, limits.stdout_bytes as usize)?;
                drain_stderr(
                    &mut stderr,
                    &mut diagnostic.stderr_bytes,
                    limits.stderr_bytes as usize,
                )?;
                diagnostic.exit_code = code;
                diagnostic.stdout_bytes = bytes.len();
                diagnostic.truncated = diagnostic.stderr_bytes > limits.stderr_bytes as usize;
                if bytes.len() > limits.stdout_bytes as usize || diagnostic.truncated {
                    diagnostic.code = "guest_git_limit";
                }
                if code != Some(0) || diagnostic.code == "guest_git_limit" {
                    return Err(std::io::Error::other(diagnostic.clone()));
                }
                return String::from_utf8(bytes)
                    .map_err(|_| std::io::Error::other(diagnostic.clone()));
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    })();
    let _ = killpg(pid, Signal::SIGKILL);
    if let Some(child) = child.as_mut() {
        let _ = child.wait();
    }
    result
}
fn drain_stdout(reader: &mut impl Read, bytes: &mut Vec<u8>, limit: usize) -> std::io::Result<()> {
    let mut buffer = [0; 1024];
    while bytes.len() <= limit {
        let bound = buffer.len().min(limit + 1 - bytes.len());
        match reader.read(&mut buffer[..bound]) {
            Ok(0) => break,
            Ok(n) => bytes.extend_from_slice(&buffer[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}
fn drain_stderr(reader: &mut impl Read, count: &mut usize, limit: usize) -> std::io::Result<()> {
    let mut buffer = [0; 1024];
    while *count <= limit {
        let bound = buffer.len().min(limit + 1 - *count);
        match reader.read(&mut buffer[..bound]) {
            Ok(0) => break,
            Ok(n) => *count += n,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}
#[derive(Clone, Debug)]
struct Diagnostic {
    code: &'static str,
    operation: &'static str,
    exit_code: Option<i32>,
    stdout_bytes: usize,
    stderr_bytes: usize,
    truncated: bool,
}
impl Diagnostic {
    fn new(operation: &str) -> Self {
        let operation = match operation {
            "init" => "init",
            "bundle" => "bundle",
            "fetch" => "fetch",
            "rev-parse" => "rev-parse",
            "merge-base" => "merge-base",
            "checkout" => "checkout",
            "diff" => "diff",
            "status" => "status",
            "stash" => "stash",
            "rebase" => "rebase",
            _ => "other",
        };
        Self {
            code: "guest_git_failed",
            operation,
            exit_code: None,
            stdout_bytes: 0,
            stderr_bytes: 0,
            truncated: false,
        }
    }
}
impl std::fmt::Display for Diagnostic {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}.{}.exit.{}.out.{}.err.{}.truncated.{}",
            self.code,
            self.operation,
            self.exit_code
                .map_or_else(|| "unknown".into(), |c| c.to_string()),
            self.stdout_bytes,
            self.stderr_bytes,
            u8::from(self.truncated)
        )
    }
}
impl std::error::Error for Diagnostic {}
fn failed(code: &'static str) -> std::io::Error {
    std::io::Error::other(code)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn output_is_bounded_and_no_stderr_or_command_material_enters_diagnostics() {
        let canary = b"public-canary-material";
        let mut count = 0;
        drain_stderr(
            &mut std::io::Cursor::new(canary.repeat(100)),
            &mut count,
            256,
        )
        .unwrap();
        assert_eq!(count, 257);
        let mut diagnostic = Diagnostic::new(std::str::from_utf8(canary).unwrap());
        diagnostic.stderr_bytes = count;
        diagnostic.truncated = true;
        let message = diagnostic.to_string();
        assert!(message.len() < 128 && message.contains("other") && message.contains("err.257"));
        assert!(!message.contains(std::str::from_utf8(canary).unwrap()));
        assert!(!format!("{diagnostic:?}").contains(std::str::from_utf8(canary).unwrap()));
        let mut out = vec![];
        drain_stdout(&mut std::io::Cursor::new(vec![255; 10000]), &mut out, 4096).unwrap();
        assert_eq!(out.len(), 4097);
    }
}
