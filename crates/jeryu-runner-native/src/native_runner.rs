#![doc = "Native runner process supervisor."]

use crate::guards::{sanitized_native_env, validate_native_plan, verify_enforcement};
use jeryu_runner_core::error::{RunnerError, RunnerResult};
use jeryu_runner_core::job::JobRequest;
use jeryu_runner_core::policy::PolicyDecision;
use jeryu_runner_core::receipt::{Receipt, ReceiptStatus, now_ms};
use jeryu_runner_core::sandbox::SandboxPlan;
use jeryu_sandbox_linux::capability::SandboxCapabilities;
use jeryu_sandbox_linux::launch::spawn_sandboxed_owned;
use jeryu_sandbox_linux::watchdog::{TerminationScope, WatchdogOptions, run_owned_with_watchdog};
use std::fs;
use std::sync::OnceLock;
use std::time::Duration;

/// Probe the host sandbox capabilities exactly once and cache the result; the
/// throwaway-child probes are cheap but pointless to repeat per job.
fn cached_capabilities() -> &'static SandboxCapabilities {
    static CAPS: OnceLock<SandboxCapabilities> = OnceLock::new();
    CAPS.get_or_init(SandboxCapabilities::probe)
}

/// Native runner supervisor.
#[derive(Debug, Default, Clone)]
pub struct NativeRunner;

impl NativeRunner {
    /// Create a native runner.
    pub fn new() -> Self {
        Self
    }

    /// Execute a job under the REAL native syscall sandbox.
    ///
    /// The pipeline is: probe host capabilities once (cached) -> validate the
    /// plan -> resolve the enforcement level -> `spawn_sandboxed_owned` (applies
    /// `PR_SET_NO_NEW_PRIVS`, cgroups, Landlock, seccomp, namespaces via
    /// `pre_exec`, FAIL-CLOSED) -> `verify_enforcement` while the child is live
    /// -> bounded output/cancellation supervision and verified cleanup.
    ///
    /// Enforcement state is first-class and honest: when the host degrades a
    /// primitive (e.g. unprivileged user namespaces are blocked, or cgroup
    /// delegation is unusable), the receipt message records exactly what was
    /// applied vs. skipped. The runner refuses to run at all when the sandbox is
    /// `Unavailable` (cannot fail closed). All unsafe lives in
    /// `jeryu-sandbox-linux`; this crate stays SAFE.
    pub fn execute(
        &self,
        job: &JobRequest,
        decision: &PolicyDecision,
        plan: &SandboxPlan,
    ) -> RunnerResult<Receipt> {
        self.execute_with_options(job, decision, plan, WatchdogOptions::default())
    }

    /// Execute with bounded capture, private spools and cooperative cancellation.
    /// Options are validated before spawn. Cancellation and output overflow use
    /// the existing failed status; no wire-protocol variant is introduced.
    pub fn execute_with_options(
        &self,
        job: &JobRequest,
        decision: &PolicyDecision,
        plan: &SandboxPlan,
        options: WatchdogOptions,
    ) -> RunnerResult<Receipt> {
        job.validate()?;
        validate_native_plan(job, plan)?;
        options.capture.validate()?;
        if options.cancellation.is_cancelled() {
            let now = now_ms();
            return Ok(Receipt::new(
                job,
                decision,
                plan,
                ReceiptStatus::Failed,
                None,
                now,
                now,
                "cancelled before sandbox launch",
            ));
        }
        fs::create_dir_all(&job.workspace)?;

        let caps = cached_capabilities();
        let level = caps.enforcement_level(plan);
        let env = sanitized_native_env(job, plan);

        let started = now_ms();
        let child = match spawn_sandboxed_owned(job, plan, caps, &env) {
            Ok(child) => child,
            Err(err) => {
                let finished = now_ms();
                // Unavailable / setup failures are fail-closed: the job did not
                // run, and the receipt explains why.
                return Ok(Receipt::new(
                    job,
                    decision,
                    plan,
                    ReceiptStatus::Failed,
                    None,
                    started,
                    finished,
                    format!("sandbox_launch_failed[{}]: {}", err.code(), err.message()),
                ));
            }
        };

        // Prove enforcement from /proc/<pid>/status while the child is live.
        let report = verify_enforcement(child.id(), &level);

        let timeout = Duration::from_millis(job.timeout_ms.max(1));
        let finished;
        let result = match run_owned_with_watchdog(child, timeout, options) {
            Ok(outcome) => {
                finished = now_ms();
                outcome
            }
            Err(err) => {
                let finished = now_ms();
                return Ok(Receipt::new(
                    job,
                    decision,
                    plan,
                    ReceiptStatus::Failed,
                    None,
                    started,
                    finished,
                    format!("watchdog_failed: {err}"),
                ));
            }
        };

        let status = if result.cancelled || result.output_limit_exceeded {
            ReceiptStatus::Failed
        } else if result.timed_out {
            ReceiptStatus::TimedOut
        } else if result.exit_code == Some(0) {
            ReceiptStatus::Passed
        } else {
            ReceiptStatus::Failed
        };

        let mut message = summarize_output(&result.stdout, &result.stderr);
        message.push_str(&format!(" enforcement={}", enforcement_summary(&report)));
        let scope = match result.termination_scope {
            TerminationScope::OwnedCgroup => "owned-cgroup",
            TerminationScope::ProcessGroup => "process-group-only",
        };
        message.push_str(&format!(" termination_scope={scope} cancelled={} output_limit_exceeded={} stdout_digest={} stderr_digest={}",
            result.cancelled, result.output_limit_exceeded, result.stdout_sha256, result.stderr_sha256));
        if result.timed_out {
            message.push_str(&format!(
                " timed_out_after_ms={}",
                result.elapsed.as_millis()
            ));
        }

        Ok(Receipt::new(
            job,
            decision,
            plan,
            status,
            result.exit_code,
            started,
            finished,
            message,
        ))
    }

    /// Build a plan-only receipt for explain mode.
    pub fn plan_only(
        &self,
        job: &JobRequest,
        decision: &PolicyDecision,
        plan: &SandboxPlan,
    ) -> RunnerResult<Receipt> {
        job.validate()?;
        validate_native_plan(job, plan)?;
        let now = now_ms();
        Ok(Receipt::new(
            job,
            decision,
            plan,
            ReceiptStatus::Planned,
            None,
            now,
            now,
            "native runner plan created",
        ))
    }
}

/// Compact, receipt-friendly summary of the proven enforcement state.
fn enforcement_summary(report: &jeryu_sandbox_linux::launch::EnforcementReport) -> String {
    format!(
        "level={} applied=[{}] skipped=[{}] proc_no_new_privs={} proc_seccomp={}",
        report.level,
        report.applied.join(","),
        report.skipped.join(","),
        report
            .proc_no_new_privs
            .map(|v| v.to_string())
            .unwrap_or_else(|| "?".to_string()),
        report
            .proc_seccomp
            .map(|v| v.to_string())
            .unwrap_or_else(|| "?".to_string()),
    )
}

fn summarize_output(stdout: &[u8], stderr: &[u8]) -> String {
    let mut message = String::new();
    if !stdout.is_empty() {
        message.push_str("stdout=");
        message.push_str(&lossy_limit(stdout, 4096));
    }
    if !stderr.is_empty() {
        if !message.is_empty() {
            message.push(' ');
        }
        message.push_str("stderr=");
        message.push_str(&lossy_limit(stderr, 4096));
    }
    if message.is_empty() {
        "process completed without output".to_string()
    } else {
        message
    }
}

fn lossy_limit(bytes: &[u8], limit: usize) -> String {
    let mut value = String::from_utf8_lossy(bytes).to_string();
    if value.len() > limit {
        let mut boundary = limit;
        while !value.is_char_boundary(boundary) {
            boundary -= 1;
        }
        value.truncate(boundary);
        value.push_str("...[truncated]");
    }
    value
}

/// Convert policy denial into a typed error when a native class is missing.
pub fn native_class_required(plan: &SandboxPlan) -> RunnerResult<()> {
    if plan.runner_class.is_native() {
        Ok(())
    } else {
        Err(RunnerError::new(
            "invalid_native_runner",
            format!("{} is not native", plan.runner_class),
        ))
    }
}

#[cfg(test)]
mod tests;
